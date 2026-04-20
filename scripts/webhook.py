#!/usr/bin/env python3
"""Tiny HMAC-authenticated webhook → triggers refresh/refresh-maxmind.

GitHub-compatible: verifies X-Hub-Signature-256 when WEBHOOK_SECRET is set.
Only starts if WEBHOOK_SECRET is provided (otherwise no endpoint is exposed).

Endpoints:
  POST /refresh           -> /usr/local/bin/refresh         (url + asn sources)
  POST /refresh-maxmind   -> /usr/local/bin/refresh-maxmind (force MaxMind too)
  GET  /healthz           -> 200 if the webhook process is alive (LIVENESS)
  GET  /ready             -> 200 iff `birdc show status` succeeds (READINESS)
                             503 otherwise — safe for load-balancer health
                             checks that must avoid nodes where bird is down.
"""

import hashlib
import hmac
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("WEBHOOK_PORT", "9090"))
SECRET = os.environ.get("WEBHOOK_SECRET", "").encode()
BIRD_CTL = os.environ.get("BIRD_CTL", "/var/run/bird/bird.ctl")

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
        path = self.path.rstrip("/")

        if path == "/healthz":
            # Liveness — this process is alive. Says nothing about bird.
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
            return

        if path == "/ready":
            # Readiness — bird is running AND responsive on its control socket.
            # Use this endpoint for load-balancer health checks.
            try:
                r = subprocess.run(
                    ["birdc", "-s", BIRD_CTL, "show", "status"],
                    capture_output=True, timeout=3, text=True,
                )
                if r.returncode == 0 and "BIRD" in r.stdout:
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b"ready\n")
                    return
                reason = (r.stderr or r.stdout or "no output").strip()[:200]
            except (subprocess.SubprocessError, OSError) as e:
                reason = f"birdc exec failed: {e}"[:200]
            self.send_response(503)
            self.end_headers()
            self.wfile.write(f"not ready: {reason}\n".encode())
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
