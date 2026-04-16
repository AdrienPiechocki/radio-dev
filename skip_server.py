#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os

SKIP_FILE = "/tmp/skip_track"

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_POST(self):
        if self.path == "/skip":
            try:
                with open(SKIP_FILE, "w") as f:
                    f.write("1")
                self._send(200, {"status": "ok", "action": "skip"})
            except Exception as e:
                self._send(500, {"status": "error", "error": str(e)})
        else:
            self._send(404, {"error": "not found"})

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})


if __name__ == "__main__":
    port = int(os.environ.get("API_PORT", 3000))
    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"🎛️ Control API running on port {port}")
    server.serve_forever()