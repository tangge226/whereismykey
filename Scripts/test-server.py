"""Loopback-only fixtures; all credentials used here are synthetic test values."""

import json
import sys
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/doc-site/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write('<html><a href="/doc-site/developers/">开发者</a></html>'.encode())
            return
        if url.path == "/doc-site/developers/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write('''<html><script>TUCUI_API_KEY="script-must-not-be-imported"</script>
                <h1>图萃开发者</h1><p>npm install --global tucui-cli</p>
                <p>服务地址与 Key 由邮件提供。</p>
                <pre>curl "$TUCUI_BASE_URL/api/query-linked" -H "X-API-Key: $TUCUI_API_KEY" -d '{"query":"研究问题"}'</pre>
                </html>'''.encode())
            return
        status = 200
        if url.path.startswith("/status/"):
            status = int(url.path.rsplit("/", 1)[1])
        elif url.path == "/header":
            status = 200 if self.headers.get("X-Tucui-Key") == "fixture-header-secret" else 401
        elif url.path == "/query":
            status = 200 if parse_qs(url.query).get("api_key") == ["fixture +/?&='secret"] else 401
        elif url.path == "/bearer":
            status = 200 if self.headers.get("Authorization") == "Bearer fixture ' quoted secret" else 401
        elif url.path == "/api/resources/available":
            status = 200 if self.headers.get("X-API-Key") == "fixture-tucui-auth-key" else 401
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"ok": status == 200, "path": self.path, "headers": dict(self.headers)}).encode())

    def do_POST(self):
        self.send_response(201)
        self.end_headers()
        self.wfile.write(b'{"created":true}')


server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
if len(sys.argv) > 2:
    Path(sys.argv[2]).write_text(str(server.server_address[1]))
server.serve_forever()
