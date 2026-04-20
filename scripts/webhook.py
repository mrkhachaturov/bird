#!/usr/bin/env python3
"""Tiny HMAC-authenticated webhook → triggers refresh/refresh-maxmind.

GitHub-compatible: verifies X-Hub-Signature-256 when WEBHOOK_SECRET is set.
Only starts if WEBHOOK_SECRET is provided (otherwise no endpoint is exposed).

Endpoints:
  POST /refresh           -> /usr/local/bin/refresh         (url + asn sources)
  POST /refresh-maxmind   -> /usr/local/bin/refresh-maxmind (force MaxMind too)
"""

import hashlib
import hmac
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("WEBHOOK_PORT", "9090"))
SECRET = os.environ.get("WEBHOOK_SECRET", "").encode()

ROUTES = {
    "/refresh": "/usr/local/bin/refresh",
    "/refresh-maxmind": "/usr/local/bin/refresh-maxmind",
}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        sig = self.headers.get("X-Hub-Signature-256", "")
        expected = "sha256=" + hmac.new(SECRET, body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expected):
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"bad signature\n")
            return

        cmd = ROUTES.get(self.path.rstrip("/"))
        if not cmd:
            self.send_response(404)
            self.end_headers()
            return

        # Fire-and-forget — fetches can take minutes; we ack immediately.
        subprocess.Popen([cmd], stdout=sys.stdout, stderr=sys.stderr)
        self.send_response(202)
        self.end_headers()
        self.wfile.write(b"accepted\n")

    def do_GET(self) -> None:
        # Simple liveness check; no secret required.
        if self.path.rstrip("/") == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(f"webhook: {fmt % args}\n")
        sys.stderr.flush()


if __name__ == "__main__":
    if not SECRET:
        print("webhook: WEBHOOK_SECRET not set — webhook server disabled", file=sys.stderr)
        sys.exit(0)
    print(f"webhook: listening on :{PORT}", file=sys.stderr, flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
