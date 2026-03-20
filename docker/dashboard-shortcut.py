import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


PORT = int(os.environ.get("PORT", "18788"))
URL_FILE = Path(os.environ.get("DASHBOARD_URL_FILE", "/state/.nemoclaw/dashboard-url.txt"))


class Handler(BaseHTTPRequestHandler):
    def _target(self) -> str:
        try:
            return URL_FILE.read_text(encoding="utf-8").strip()
        except Exception:
            return ""

    def _respond(self, include_body: bool) -> None:
        target = self._target()
        if not target:
            body = b"Dashboard URL is not ready yet. Check control container logs."
            self.send_response(503)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if include_body:
                self.wfile.write(body)
            return

        self.send_response(302)
        self.send_header("Location", target)
        self.end_headers()

    def do_GET(self) -> None:
        self._respond(include_body=True)

    def do_HEAD(self) -> None:
        self._respond(include_body=False)

    def log_message(self, format: str, *args) -> None:
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()