"""Start a DAV server on a private ephemeral port for the backup transport test."""

import sys
from pathlib import Path

from cheroot.wsgi import Server
from wsgidav.wsgidav_app import WsgiDAVApp


root = Path(sys.argv[1])
root.mkdir()
app = WsgiDAVApp({
    "provider_mapping": {"/dav": str(root)},
    "simple_dc": {"user_mapping": {"*": True}},
    "verbose": 0,
    "logging": {"enable": False},
})

def trace(environ, start_response):
    def record(status, headers, exc_info=None):
        condition = {key: environ[key] for key in
                     ("HTTP_IF_MATCH", "HTTP_IF_NONE_MATCH", "HTTP_IF_UNMODIFIED_SINCE") if key in environ}
        metadata = {key: value for key, value in headers if key.lower() in ("etag", "content-length")}
        print(environ["REQUEST_METHOD"], environ["PATH_INFO"], condition, status, metadata, flush=True)
        return start_response(status, headers, exc_info)

    return app(environ, record)


server = Server(("127.0.0.1", 0), trace)
server.prepare()
Path(sys.argv[2]).write_text(str(server.bind_addr[1]))
server.serve()
