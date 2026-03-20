import http.client
import os
import select
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


PORT = int(os.environ.get("PORT", "18790"))
TARGET_ORIGIN = os.environ.get("TARGET_ORIGIN", "http://127.0.0.1:18789").rstrip("/")
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


def rewrite_forwarded_origin_headers(headers: dict[str, str]) -> None:
    if "Origin" in headers:
        headers["Origin"] = TARGET_ORIGIN
    if "Referer" in headers:
        headers["Referer"] = TARGET_ORIGIN + "/"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _is_websocket_upgrade(self) -> bool:
        connection = self.headers.get("Connection", "")
        upgrade = self.headers.get("Upgrade", "")
        return "upgrade" in connection.lower() and upgrade.lower() == "websocket"

    def _proxy_websocket(self) -> None:
        target = urlsplit(TARGET_ORIGIN)
        backend_sock = socket.create_connection((target.hostname, target.port or 80), timeout=30)

        request_headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() in WEBSOCKET_REQUEST_HEADERS
        }
        request_headers["Host"] = target.netloc
        rewrite_forwarded_origin_headers(request_headers)

        lines = [f"{self.command} {self.path or '/'} HTTP/1.1"]
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
        target = urlsplit(TARGET_ORIGIN)
        if self._is_websocket_upgrade():
            self._proxy_websocket()
            return
        body = None
        length = self.headers.get("Content-Length")
        if length:
            body = self.rfile.read(int(length))

        connection = http.client.HTTPConnection(target.hostname, target.port or 80, timeout=30)
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() in FORWARDED_REQUEST_HEADERS
        }
        headers["Host"] = target.netloc
        headers["Accept-Encoding"] = "identity"
        rewrite_forwarded_origin_headers(headers)
        try:
            connection.request(self.command, self.path or "/", body=body, headers=headers)
            response = connection.getresponse()
        except Exception:
            connection.close()
            error_body = b"OpenClaw dashboard bridge backend is unavailable."
            self.send_response(502)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(error_body)))
            self.end_headers()
            if include_body:
                self.wfile.write(error_body)
            return

        self.send_response(response.status)
        for key, value in response.getheaders():
            if key.lower() in HOP_BY_HOP_HEADERS:
                continue
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