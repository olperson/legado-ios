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
server = Server(("127.0.0.1", 0), app)
server.prepare()
Path(sys.argv[2]).write_text(str(server.bind_addr[1]))
server.serve()
