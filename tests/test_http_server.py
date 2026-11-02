from functools import partial
from http.client import HTTPConnection
from http.server import SimpleHTTPRequestHandler
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread
import unittest
from unittest.mock import patch

from http_server import LoopbackHTTPServer


class LoopbackFixtureTests(unittest.TestCase):
    def test_serves_payload_when_reverse_dns_is_unavailable(self):
        with TemporaryDirectory() as root:
            Path(root, "payload").write_text("fixture works\n")
            handler = partial(SimpleHTTPRequestHandler, directory=root)
            with patch("socket.getfqdn", side_effect=AssertionError("DNS is forbidden")):
                with LoopbackHTTPServer(("127.0.0.1", 0), handler) as server:
                    thread = Thread(target=server.serve_forever, daemon=True)
                    thread.start()
                    try:
                        connection = HTTPConnection("127.0.0.1", server.server_port, timeout=2)
                        connection.request("GET", "/payload")
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertEqual(response.read(), b"fixture works\n")
                        connection.close()
                    finally:
                        server.shutdown()
                        thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
