#!/usr/bin/env python3
"""A loopback fixture with an OS-assigned port and an explicit ready file."""
import faulthandler
import sys

faulthandler.enable()
faulthandler.dump_traceback_later(5, repeat=True)
print(f"HTTP fixture interpreter: {sys.executable}", file=sys.stderr, flush=True)

from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root, ready = sys.argv[1:]
print("HTTP fixture binding loopback", file=sys.stderr, flush=True)
server = ThreadingHTTPServer(
    ("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=root)
)
temporary = Path(ready + ".tmp")
temporary.write_text(f"http://127.0.0.1:{server.server_port}\n")
temporary.replace(ready)
faulthandler.cancel_dump_traceback_later()
server.serve_forever()
