"""Controlled HTTP transfers for the native downloader integration check."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time

DATA = bytes(range(256)) * 8192

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.split('?', 1)[0]
        if name == '/missing':
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Length', str(len(DATA)))
        self.end_headers()
        try:
            for offset in range(0, len(DATA), 32768):
                self.wfile.write(DATA[offset:offset + 32768])
                self.wfile.flush()
                if name == '/slow':
                    time.sleep(0.04)
        except (BrokenPipeError, ConnectionResetError):
            pass

ThreadingHTTPServer(('127.0.0.1', 18765), Handler).serve_forever()
