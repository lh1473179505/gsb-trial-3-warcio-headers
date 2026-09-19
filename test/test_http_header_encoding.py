#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Tests that non-ASCII bytes in HTTP header blocks are preserved verbatim
when writing WARC records, instead of being rewritten as UTF-8
%-encoded text (eg. 0xff -> %C3%BF).

The HTTP header block is part of the stored network response and must be
archived as it was received, byte-for-byte.
"""

from io import BytesIO
from warcio.warcwriter import BufferWARCWriter
from warcio.statusandheaders import StatusAndHeaders, StatusAndHeadersParser
from warcio.recordloader import ArcWarcRecordLoader
from warcio.archiveiterator import ArchiveIterator

from . import check_helper


def _write_response(writer, payload, **kwargs):
    record = writer.create_warc_record(
        'http://example.com/', 'response',
        payload=BytesIO(payload),
        length=kwargs.pop('length', len(payload)),
        **kwargs)
    writer.write_record(record)
    return writer.get_contents()


# ============================================================================
class TestRawHeaderBytesPreserved(object):
    def test_payload_header_with_0xff_not_percent_encoded(self):
        """Reproduces the reported bug: a header value containing the
        single Latin-1 byte 0xff must not be written as %C3%BF."""
        payload = b'HTTP/1.0 200 OK\r\n' \
                  b'Content-Type: text/plain\r\n' \
                  b'X-Latin1: \xff\r\n' \
                  b'\r\n' \
                  b'some text'

        writer = BufferWARCWriter(gzip=False)
        buff = _write_response(writer, payload)

        assert b'X-Latin1: \xff\r\n' in buff
        assert b'%C3%BF' not in buff
        assert b'%FF' not in buff

    def test_explicit_http_headers_latin1_str_value(self):
        """StatusAndHeaders values with Latin-1 semantics (single 0xff
        char) are written as the single byte 0xff."""
        http_headers = StatusAndHeaders('200 OK',
                                        [('X-Latin1', '\xff')],
                                        protocol='HTTP/1.0')

        writer = BufferWARCWriter(gzip=False)
        buff = _write_response(writer, b'some text', http_headers=http_headers)

        assert b'X-Latin1: \xff\r\n' in buff
        assert b'%C3%BF' not in buff

    def test_explicit_http_headers_bytes_value(self):
        http_headers = StatusAndHeaders('200 OK',
                                        [(b'X-Latin1', b'\xff\xfe')],
                                        protocol='HTTP/1.0')

        writer = BufferWARCWriter(gzip=False)
        buff = _write_response(writer, b'some text', http_headers=http_headers)

        assert b'X-Latin1: \xff\xfe\r\n' in buff
        assert b'%C3%BF' not in buff

    def test_gzipped_write_preserves_raw_bytes(self):
        payload = b'HTTP/1.0 200 OK\r\nX-Latin1: \xff\r\n\r\nbody'

        writer = BufferWARCWriter(gzip=True)
        buff = _write_response(writer, payload)

        for record in ArchiveIterator(BytesIO(buff)):
            assert record.http_headers.get_header('X-Latin1') == '\xff'
            assert record.content_stream().read() == b'body'

    def test_read_back_block_digest_matches_raw_bytes(self):
        payload = b'HTTP/1.0 200 OK\r\nX-Latin1: \xff\r\n\r\nbody'

        writer = BufferWARCWriter(gzip=False)
        buff = _write_response(writer, payload)

        # warcio check-style verification passes: the block digest is
        # computed over the raw header bytes that were actually stored
        for record in ArchiveIterator(BytesIO(buff), check_digests='raise'):
            assert record.content_stream().read() == b'body'

    def test_header_block_byte_exact_roundtrip(self):
        """Reading an existing WARC and writing it back keeps the
        complete HTTP header block byte-for-byte, including
        non-ASCII bytes."""
        payload = (b'HTTP/1.0 200 OK\r\n'
                   b'Content-Type: text/plain\r\n'
                   b'X-Latin1: \xff\r\n'
                   b'X-More: value \x80\x81\r\n'
                   b'\r\n'
                   b'body')

        writer = BufferWARCWriter(gzip=False)
        buff = _write_response(writer, payload)

        for gzip_in, gzip_out in ((False, False), (False, True),
                                  (True, False), (True, True)):
            original = BufferWARCWriter(gzip=gzip_in)
            original.write_record(
                ArcWarcRecordLoader().parse_record_stream(BytesIO(buff)))
            original_buff = original.get_contents()

            rewritten = BufferWARCWriter(gzip=gzip_out)
            for record in ArchiveIterator(BytesIO(original_buff)):
                rewritten.write_record(record)

            read_back = []
            for record in ArchiveIterator(BytesIO(rewritten.get_contents())):
                read_back.append((record.http_headers.headers_buff,
                                  record.content_stream().read()))

            assert len(read_back) == 1
            headers_buff, body = read_back[0]
            assert headers_buff == (
                b'HTTP/1.0 200 OK\r\n'
                b'Content-Type: text/plain\r\n'
                b'X-Latin1: \xff\r\n'
                b'X-More: value \x80\x81\r\n'
                b'\r\n')
            assert body == b'body'

    def test_parser_stores_raw_header_block(self):
        raw = b'HTTP/1.0 200 OK\r\nX-Latin1: \xff\r\n  folded\r\n\r\n'
        parsed = StatusAndHeadersParser(['HTTP/1.0']).parse(BytesIO(raw))
        assert parsed.headers_buff == raw

    def test_header_modification_invalidates_raw_block(self):
        raw = b'HTTP/1.0 200 OK\r\nX-Latin1: \xff\r\nX-Old: a\r\n\r\n'
        parsed = StatusAndHeadersParser(['HTTP/1.0']).parse(BytesIO(raw))

        parsed.replace_header('X-Old', 'b')
        parsed.remove_header('X-Latin1')
        parsed.add_header('X-New', 'c')

        writer = BufferWARCWriter(gzip=False)
        writer.write_record(
            writer.create_warc_record(
                'http://example.com/', 'response',
                payload=BytesIO(b'body'), length=4, http_headers=parsed))
        out = writer.get_contents()
        assert b'X-Old: b\r\n' in out
        assert b'X-New: c\r\n' in out
        assert b'X-Latin1' not in out

    def test_ascii_headers_unchanged(self):
        payload = (b'HTTP/1.0 200 OK\r\n'
                   b'Content-Type: text/plain\r\n'
                   b'Custom-Header: somevalue\r\n'
                   b'\r\n'
                   b'some\ntext')

        writer = BufferWARCWriter(gzip=False)
        buff = _write_response(writer, payload)

        assert payload in buff
        assert b'\xff' not in buff

    def test_non_latin1_unicode_still_serializable(self):
        """Genuine unicode values that cannot map to a Latin-1 byte
        still serialize via the UTF-8 %-encoding fallback."""
        http_headers = StatusAndHeaders(
            '200 OK',
            [('Content-Disposition',
              u'attachment; filename="испытание"')],
            protocol='HTTP/1.0')

        writer = BufferWARCWriter(gzip=False)
        buff = _write_response(writer, b'body', http_headers=http_headers)

        assert b"filename*=UTF-8''%D0%B8%D1%81%D0%BF%D1%8B%D1%82%D0%B0%D0%BD%D0%B8%D0%B5" in buff

    def test_opt_in_percent_encoding(self):
        """The legacy UTF-8 %-encoding remains available as an
        explicit opt-in."""
        http_headers = StatusAndHeaders('200 OK',
                                        [('X-Latin1', '\xff')],
                                        protocol='HTTP/1.0')

        writer = BufferWARCWriter(gzip=False,
                                  encode_non_ascii_headers=True)
        buff = _write_response(writer, b'body', http_headers=http_headers)

        assert b'X-Latin1: %C3%BF\r\n' in buff
        assert b'X-Latin1: \xff' not in buff

    def test_to_ascii_bytes_explicit_path_unchanged(self):
        headers = StatusAndHeaders('200 OK',
                                   [('Custom-Header', 'attachment; filename="Éxamplè"')])
        res = headers.to_ascii_bytes().decode('ascii')
        assert res == (
            "200 OK\r\n"
            "Custom-Header: attachment; filename*=UTF-8''%C3%89xampl%C3%A8\r\n"
            "\r\n")

    def test_to_raw_bytes_latin1(self):
        headers = StatusAndHeaders('200 OK', [('X-Latin1', '\xff')])
        assert headers.to_raw_bytes() == b'200 OK\r\nX-Latin1: \xff\r\n\r\n'

    def test_cli_check_passes(self, tmp_path, capsys):
        payload = b'HTTP/1.0 200 OK\r\nX-Latin1: \xff\r\n\r\nbody'

        writer = BufferWARCWriter(gzip=True)
        buff = _write_response(writer, payload)

        path = tmp_path / 'latin1.warc.gz'
        path.write_bytes(buff)

        check_helper(['check', str(path)], capsys, 0)
