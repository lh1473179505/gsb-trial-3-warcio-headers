# -*- coding: utf-8 -*-
"""
Tests that non-ASCII HTTP header bytes received on the wire are written
to WARC records byte-for-byte, instead of being rewritten as UTF-8
percent-encoded values (eg. 0xff -> %C3%BF).
"""

from io import BytesIO

import pytest

from warcio.archiveiterator import ArchiveIterator
from warcio.bufferedreaders import DecompressingBufferedReader
from warcio.cli import main
from warcio.statusandheaders import StatusAndHeaders
from warcio.warcwriter import BufferWARCWriter, WARCWriter


URI = 'http://example.com/'

# a response with a single non-ASCII (latin-1, 0xff) byte in a header,
# the historical-server case described in the bug report
RAW_PAYLOAD = (b'HTTP/1.1 200 OK\r\n'
               b'Content-Type: text/plain\r\n'
               b'X-Latin1-Header: value-\xff-end\r\n'
               b'\r\n'
               b'body')

ASCII_PAYLOAD = (b'HTTP/1.1 200 OK\r\n'
                 b'Content-Type: text/plain\r\n'
                 b'X-Ascii-Header: somevalue\r\n'
                 b'\r\n'
                 b'body')


def _write_payload(writer, payload):
    record = writer.create_warc_record(URI, 'response',
                                       payload=BytesIO(payload),
                                       length=len(payload))
    writer.write_record(record)
    return writer.get_contents()


def _raw_contents(buff, gzip):
    if not gzip:
        return buff

    return DecompressingBufferedReader(BytesIO(buff)).read()


@pytest.mark.parametrize('gzip', [False, True])
def test_payload_latin1_header_bytes_preserved(gzip):
    """Requirement 1: a non-ASCII byte in a header embedded in the
    payload must be written as the same raw byte, not as %C3%BF."""
    out = _raw_contents(_write_payload(BufferWARCWriter(gzip=gzip), RAW_PAYLOAD),
                        gzip)

    assert b'X-Latin1-Header: value-\xff-end\r\n' in out
    assert b'%C3%BF' not in out
    assert b'value-\xc3\xbf' not in out


@pytest.mark.parametrize('gzip', [False, True])
def test_explicit_http_headers_latin1_preserved(gzip):
    """Requirement 2: explicitly built StatusAndHeaders whose values
    carry latin-1/raw-byte semantics (passed as bytes or as a latin-1
    decoded str) must be written back as the original bytes."""
    writer = BufferWARCWriter(gzip=gzip)
    http_headers = StatusAndHeaders('200 OK', [
        ('Content-Type', 'text/plain'),
        ('X-Raw-Bytes', b'raw-\xff'),
        ('X-Raw-Str', 'str-\xff-end'),
    ], protocol='HTTP/1.1')

    record = writer.create_warc_record(URI, 'response',
                                       payload=BytesIO(b'body'),
                                       length=4,
                                       http_headers=http_headers)
    writer.write_record(record)
    out = _raw_contents(writer.get_contents(), gzip)

    assert b'X-Raw-Bytes: raw-\xff\r\n' in out
    assert b'X-Raw-Str: str-\xff-end\r\n' in out
    assert b'%C3%BF' not in out


def test_ascii_headers_unchanged():
    """Requirement 3: pure ASCII headers keep their existing behavior."""
    out = _write_payload(BufferWARCWriter(gzip=False), ASCII_PAYLOAD)
    assert out[out.index(b'HTTP/1.1'):] == (
        b'HTTP/1.1 200 OK\r\n'
        b'Content-Type: text/plain\r\n'
        b'X-Ascii-Header: somevalue\r\n'
        b'\r\n'
        b'body\r\n\r\n')


def test_true_unicode_header_still_percent_encoded():
    """Requirement 3: genuine unicode string headers (characters that
    could never be received as raw latin-1 bytes) still use the
    percent-encoding fallback so writing never fails."""
    writer = BufferWARCWriter(gzip=False)
    http_headers = StatusAndHeaders('200 OK', [
        ('Content-Disposition', 'attachment; filename="испытание.txt"'),
        ('X-Emoji', '📁 text'),
    ], protocol='HTTP/1.1')

    record = writer.create_warc_record(URI, 'response',
                                       payload=BytesIO(b'body'),
                                       length=4,
                                       http_headers=http_headers)
    writer.write_record(record)
    out = writer.get_contents()

    assert b"filename*=UTF-8''%D0%B8%D1%81%D0%BF%D1%8B%D1%82%D0%B0%D0%BD%D0%B8%D0%B5.txt\r\n" in out
    assert b'X-Emoji: %F0%9F%93%81%20text\r\n' in out


def test_explicit_to_ascii_bytes_path_still_available():
    """The percent-encoding path remains available explicitly: calling
    to_ascii_bytes() still UTF-8 percent-encodes non-ASCII headers."""
    sh = StatusAndHeaders('200 OK', [('Custom-Header', 'value-\xff-end')])
    out = sh.to_ascii_bytes()
    assert b'Custom-Header: value-%C3%BF-end\r\n' in out


def test_archive_iterator_reads_raw_header():
    out = _write_payload(BufferWARCWriter(gzip=False), RAW_PAYLOAD)
    record = next(ArchiveIterator(BytesIO(out)))

    # each raw byte maps to a single latin-1 codepoint
    assert record.http_headers.get_header('X-Latin1-Header') == 'value-\xff-end'
    assert record.content_stream().read() == b'body'


def test_read_rewrite_roundtrips_raw_bytes():
    """Requirement 4: reading an existing WARC and writing it back must
    keep the HTTP header block byte-for-byte identical."""
    out = _write_payload(BufferWARCWriter(gzip=False), RAW_PAYLOAD)

    record = next(ArchiveIterator(BytesIO(out)))

    writer = BufferWARCWriter(gzip=False)
    writer.write_record(record)
    rewritten = writer.get_contents()

    block = out[out.index(b'HTTP/1.1'):]
    rewritten_block = rewritten[rewritten.index(b'HTTP/1.1'):]
    assert block == rewritten_block
    assert b'X-Latin1-Header: value-\xff-end\r\n' in rewritten


def test_utf8_header_in_existing_warc_roundtrips():
    """A header containing valid UTF-8 bytes in an existing WARC also
    round-trips as raw bytes (previously it was percent-encoded)."""
    header_line = 'X-Cyrillic: испытание'.encode('utf-8')
    payload = (b'HTTP/1.1 200 OK\r\n'
               + header_line + b'\r\n'
               + b'\r\n'
               + b'body')

    out = _write_payload(BufferWARCWriter(gzip=False), payload)

    record = next(ArchiveIterator(BytesIO(out)))
    writer = BufferWARCWriter(gzip=False)
    writer.write_record(record)
    rewritten = writer.get_contents()

    assert header_line + b'\r\n' in rewritten
    assert b'%D0%B8' not in rewritten
    assert out[out.index(b'HTTP/1.1'):] == rewritten[rewritten.index(b'HTTP/1.1'):]


def test_gzip_rewrite_roundtrips_raw_bytes():
    """Same round-trip check for a gzipped WARC."""
    out = _write_payload(BufferWARCWriter(gzip=True), RAW_PAYLOAD)

    record = next(ArchiveIterator(BytesIO(out)))

    writer = BufferWARCWriter(gzip=True)
    writer.write_record(record)

    record2 = next(ArchiveIterator(BytesIO(writer.get_contents())))
    assert record2.http_headers.get_header('X-Latin1-Header') == 'value-\xff-end'
    assert record2.content_stream().read() == b'body'


def test_warc_check_passes_on_latin1_headers(tmp_path):
    """`warcio check` must pass (digests are computed over the raw
    header bytes) for records containing non-ASCII header bytes."""
    path = tmp_path / 'latin1.warc.gz'
    with open(str(path), 'wb') as fh:
        writer = WARCWriter(fh, gzip=True)
        record = writer.create_warc_record(URI, 'response',
                                           payload=BytesIO(RAW_PAYLOAD),
                                           length=len(RAW_PAYLOAD))
        writer.write_record(record)

    with pytest.raises(SystemExit) as exc_info:
        main(args=['check', str(path)])

    assert exc_info.value.code == 0
