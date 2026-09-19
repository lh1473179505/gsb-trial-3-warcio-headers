"""Local HTTP/1.1 transport adapter. Forward bytes unchanged, without retries."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.request
import urllib.error
import time

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def do_GET(self):
        self.forward()
    def do_POST(self):
        self.forward()
    def forward(self):
        if not self.path.startswith('/v1/'):
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))) if self.command == 'POST' else None
        headers = {k:v for k,v in self.headers.items() if k.lower() not in ['host', 'connection', 'content-length', 'transfer-encoding']}
        headers['Connection'] = 'close'
        request = urllib.request.Request('https://gsb.zhihejob.cn' + self.path, data=body, headers=headers, method=self.command)
        try:
            response = urllib.request.urlopen(request, timeout=300)
        except urllib.error.HTTPError as error:
            response = error
        except Exception as error:
            print(time.time(), self.command, self.path, type(error).__name__, flush=True)
            self.send_error(502, 'Upstream connection failed')
            return
        print(time.time(), self.command, self.path, response.status, flush=True)
        self.send_response(response.status)
        for k,v in response.headers.items():
            if k.lower() not in ['connection', 'transfer-encoding', 'content-length']:
                self.send_header(k,v)
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        try:
            while True:
                chunk = response.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        finally:
            response.close()

print('HTTP/1.1 adapter listening on 127.0.0.1:18742; retries disabled', flush=True)
ThreadingHTTPServer(('127.0.0.1', 18742), Handler).serve_forever()
