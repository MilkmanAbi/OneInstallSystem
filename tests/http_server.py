#!/usr/bin/env python3
"""A loopback fixture with an OS-assigned port and an explicit ready file."""
import faulthandler
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
import sys


class LoopbackHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind calls getfqdn(), which can hang in macOS's
        # resolver even for 127.0.0.1. Fixtures must never depend on DNS.
        TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


def main():
    faulthandler.enable()
    faulthandler.dump_traceback_later(5, repeat=True)
    print(f"HTTP fixture interpreter: {sys.executable}", file=sys.stderr, flush=True)
    root, ready = sys.argv[1:]
    with LoopbackHTTPServer(
        ("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=root)
    ) as server:
        temporary = Path(ready + ".tmp")
        temporary.write_text(f"http://127.0.0.1:{server.server_port}\n")
        temporary.replace(ready)
        faulthandler.cancel_dump_traceback_later()
        server.serve_forever()


if __name__ == "__main__":
    main()
