"""Start a DAV server on a private ephemeral port for the backup transport test."""

import sys
from pathlib import Path
from zipfile import ZipFile

from cheroot.wsgi import Server
from wsgidav.wsgidav_app import WsgiDAVApp


root = Path(sys.argv[1])
public = root / "public"
inbox = public / "inbox"
inbox.mkdir(parents=True)
history = public / "ui-history"
history.mkdir()
with ZipFile(history / "connection-sample.zip", "w") as sample:
    sample.writestr("bookshelf.json", "[]")
private = root / "private"
private.mkdir()
app = WsgiDAVApp({
    "provider_mapping": {"/dav": str(public), "/upload-only": str(inbox), "/private": str(private)},
    "simple_dc": {"user_mapping": {"*": True, "/private": {"reader": {"password": "test"}}}},
    "http_authenticator": {"accept_basic": True, "accept_digest": False, "default_to_digest": False},
    "verbose": 0,
    "logging": {"enable": False},
})

def trace(environ, start_response):
    path = environ["PATH_INFO"].encode("latin-1").decode("utf-8", errors="replace")
    request_headers = {key: environ[key] for key in ("HTTP_IF_MATCH", "HTTP_IF_NONE_MATCH",
                       "HTTP_IF_UNMODIFIED_SINCE", "HTTP_DEPTH", "HTTP_OVERWRITE") if key in environ}
    def record(status, headers, exc_info=None):
        metadata = {key: value for key, value in headers if key.lower() in ("etag", "content-length")}
        print(environ["REQUEST_METHOD"], path, request_headers, status, metadata, flush=True)
        return start_response(status, headers, exc_info)

    if (path == "/upload-only" or path.startswith("/upload-only/")) and environ["REQUEST_METHOD"] != "PUT":
        record("403 Forbidden", [("Content-Length", "0")])
        return [b""]
    return app(environ, record)


server = Server(("127.0.0.1", 0), trace)
server.prepare()
Path(sys.argv[2]).write_text(str(server.bind_addr[1]))
server.serve()
