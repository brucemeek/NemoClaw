import http.client
import os
import select
import socket
import threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import SplitResult, parse_qsl, urlencode, urlsplit, urlunsplit


PORT = int(os.environ.get("PORT", "18788"))
URL_FILE = Path(os.environ.get("DASHBOARD_URL_FILE", "/state/.nemoclaw/dashboard-url.txt"))
PROXY_ORIGIN = os.environ.get("DASHBOARD_PROXY_ORIGIN", "").strip()
PROXY_PORT = os.environ.get("DASHBOARD_PROXY_PORT", "").strip()
TOKEN_COOKIE = "nemoclaw_dashboard_token"
HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}
FORWARDED_REQUEST_HEADERS = {
    "accept",
    "accept-language",
    "cache-control",
    "content-length",
    "content-type",
    "cookie",
    "origin",
    "pragma",
    "referer",
    "user-agent",
}
WEBSOCKET_REQUEST_HEADERS = {
    "connection",
    "cookie",
    "origin",
    "pragma",
    "referer",
    "sec-websocket-extensions",
    "sec-websocket-key",
    "sec-websocket-protocol",
    "sec-websocket-version",
    "upgrade",
    "user-agent",
}


def resolve_default_gateway() -> str:
    try:
        with open("/proc/net/route", encoding="utf-8") as route_file:
            next(route_file, None)
            for line in route_file:
                fields = line.strip().split()
                if len(fields) < 3:
                    continue
                destination, gateway_hex = fields[1], fields[2]
                if destination != "00000000":
                    continue
                octets = [str(int(gateway_hex[index:index + 2], 16)) for index in range(0, 8, 2)]
                return ".".join(reversed(octets))
    except Exception:
        return ""
    return ""


def resolve_backend_origin(target: str) -> str:
    if PROXY_ORIGIN:
        return PROXY_ORIGIN.rstrip("/")

    parsed = urlsplit(target)
    hostname = parsed.hostname or ""
    if hostname in {"127.0.0.1", "localhost"}:
        port = int(PROXY_PORT) if PROXY_PORT else (parsed.port or 80)
        scheme = parsed.scheme or "http"
        gateway = resolve_default_gateway()
        if gateway:
            return f"{scheme}://{gateway}:{port}"
        return f"{scheme}://host.docker.internal:{port}"
    return urlunsplit(SplitResult(parsed.scheme, parsed.netloc, "", "", "")).rstrip("/")


def build_public_location(handler: BaseHTTPRequestHandler, fragment: str) -> str:
    host = handler.headers.get("Host") or f"127.0.0.1:{PORT}"
    suffix = f"#{fragment}" if fragment else ""
    return f"http://{host}{handler.path}{suffix}"


def build_bootstrap_location(handler: BaseHTTPRequestHandler, fragment: str) -> str:
    host = handler.headers.get("Host") or f"127.0.0.1:{PORT}"
    params = dict(parse_qsl(fragment, keep_blank_values=True)) if fragment else {}
    params["gatewayUrl"] = f"ws://{host}"
    suffix = f"#{urlencode(params)}" if params else ""
    return f"http://{host}/index.html{suffix}"


def relay_bidirectional(client_sock: socket.socket, backend_sock: socket.socket) -> None:
    sockets = [client_sock, backend_sock]
    try:
        while True:
            readable, _, _ = select.select(sockets, [], [], 30)
            if not readable:
                continue
            for source in readable:
                data = source.recv(65536)
                if not data:
                    return
                target = backend_sock if source is client_sock else client_sock
                target.sendall(data)
    finally:
        try:
            backend_sock.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            backend_sock.close()
        except Exception:
            pass
        try:
            client_sock.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            client_sock.close()
        except Exception:
            pass


def rewrite_forwarded_origin_headers(headers: dict[str, str], backend_origin: str) -> None:
    if "Origin" in headers:
        headers["Origin"] = backend_origin
    if "Referer" in headers:
        headers["Referer"] = backend_origin + "/"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _target(self) -> str:
        try:
            return URL_FILE.read_text(encoding="utf-8").strip()
        except Exception:
            return ""

    def _send_not_ready(self, include_body: bool) -> None:
        body = b"Dashboard URL is not ready yet. Check control container logs."
        self.send_response(503)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def _needs_token_redirect(self, parsed_target) -> bool:
        if not parsed_target.fragment:
            return False
        if self.command not in {"GET", "HEAD"}:
            return False
        if self.path not in {"", "/"}:
            return False
        if self.headers.get("Cookie", "").find(f"{TOKEN_COOKIE}=1") != -1:
            return False
        accept = self.headers.get("Accept", "")
        return "text/html" in accept or accept in {"", "*/*"}

    def _is_websocket_upgrade(self) -> bool:
        connection = self.headers.get("Connection", "")
        upgrade = self.headers.get("Upgrade", "")
        return "upgrade" in connection.lower() and upgrade.lower() == "websocket"

    def _send_token_bootstrap(self, parsed_target, include_body: bool) -> None:
        location = build_bootstrap_location(self, parsed_target.fragment)
        html = f"""<!doctype html>
<html lang=\"en\">
  <head>
    <meta charset=\"utf-8\" />
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
    <title>Opening OpenClaw...</title>
    <meta http-equiv=\"Cache-Control\" content=\"no-store\" />
  </head>
  <body>
    <p>Opening OpenClaw dashboard...</p>
    <script>
      document.cookie = \"{TOKEN_COOKIE}=1; Path=/; SameSite=Lax\";
      window.location.replace({location!r});
    </script>
    <noscript>
      <p><a href=\"{location}\">Continue to OpenClaw</a></p>
    </noscript>
  </body>
</html>
""".encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(html)))
        self.end_headers()
        if include_body:
            self.wfile.write(html)

    def _rewrite_location(self, location: str, backend_origin: str) -> str:
        if not location:
            return location
        public_origin = f"http://{self.headers.get('Host') or f'127.0.0.1:{PORT}'}"
        if location.startswith(backend_origin):
            return public_origin + location[len(backend_origin):]
        if location.startswith("/"):
            return public_origin + location
        return location

    def _proxy_websocket(self) -> None:
        target = self._target()
        if not target:
            self._send_not_ready(include_body=True)
            return

        backend_origin = resolve_backend_origin(target)
        backend_url = urlsplit(backend_origin)
        backend_sock = socket.create_connection((backend_url.hostname, backend_url.port or 80), timeout=30)

        request_path = self.path or "/"
        request_headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() in WEBSOCKET_REQUEST_HEADERS
        }
        request_headers["Host"] = backend_url.netloc
        rewrite_forwarded_origin_headers(request_headers, backend_origin)

        lines = [f"{self.command} {request_path} HTTP/1.1"]
        for key, value in request_headers.items():
            lines.append(f"{key}: {value}")
        lines.append("")
        lines.append("")
        backend_sock.sendall("\r\n".join(lines).encode("utf-8"))

        response = b""
        while b"\r\n\r\n" not in response:
            chunk = backend_sock.recv(65536)
            if not chunk:
                break
            response += chunk
        self.connection.sendall(response)
        self.close_connection = True
        relay_bidirectional(self.connection, backend_sock)

    def _proxy(self, include_body: bool) -> None:
        target = self._target()
        if not target:
            self._send_not_ready(include_body)
            return

        parsed_target = urlsplit(target)
        if self._is_websocket_upgrade():
            self._proxy_websocket()
            return
        if self._needs_token_redirect(parsed_target):
            self._send_token_bootstrap(parsed_target, include_body)
            return

        backend_origin = resolve_backend_origin(target)
        backend_url = urlsplit(backend_origin)
        request_path = self.path or "/"
        body = None
        length = self.headers.get("Content-Length")
        if length:
            body = self.rfile.read(int(length))

        connection = http.client.HTTPConnection(backend_url.hostname, backend_url.port or 80, timeout=30)
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() in FORWARDED_REQUEST_HEADERS
        }
        headers["Host"] = backend_url.netloc
        headers["Accept-Encoding"] = "identity"
        rewrite_forwarded_origin_headers(headers, backend_origin)
        headers["X-Forwarded-Host"] = self.headers.get("Host") or f"127.0.0.1:{PORT}"
        headers["X-Forwarded-Proto"] = "http"
        try:
            connection.request(self.command, request_path, body=body, headers=headers)
            response = connection.getresponse()
        except Exception:
            connection.close()
            error_body = b"OpenClaw dashboard backend is unavailable."
            self.send_response(502)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(error_body)))
            self.end_headers()
            if include_body:
                self.wfile.write(error_body)
            return

        self.send_response(response.status)
        for key, value in response.getheaders():
            lower = key.lower()
            if lower in HOP_BY_HOP_HEADERS:
                continue
            if lower == "location":
                value = self._rewrite_location(value, backend_origin)
            self.send_header(key, value)
        self.end_headers()
        if include_body:
            self.wfile.write(response.read())
        else:
            response.read()
        connection.close()

    def do_GET(self) -> None:
        self._proxy(include_body=True)

    def do_HEAD(self) -> None:
        self._proxy(include_body=False)

    def do_POST(self) -> None:
        self._proxy(include_body=True)

    def do_PUT(self) -> None:
        self._proxy(include_body=True)

    def do_PATCH(self) -> None:
        self._proxy(include_body=True)

    def do_DELETE(self) -> None:
        self._proxy(include_body=True)

    def do_OPTIONS(self) -> None:
        self._proxy(include_body=False)

    def log_message(self, format: str, *args) -> None:
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()