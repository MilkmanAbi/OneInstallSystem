#!/usr/bin/env python3
"""A loopback fixture with an OS-assigned port and an explicit ready file."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys

root, ready = sys.argv[1:]
server = ThreadingHTTPServer(
    ("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=root)
)
temporary = Path(ready + ".tmp")
temporary.write_text(f"http://127.0.0.1:{server.server_port}\n")
temporary.replace(ready)
server.serve_forever()
