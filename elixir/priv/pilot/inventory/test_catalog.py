"""Offline HTTP checks for the catalog surface and its release configuration."""

import argparse
from http.client import HTTPConnection
import json
import threading
import unittest

from inventory import build_server


class CatalogTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = build_server(0, quiet=True)
        cls.worker = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.worker.join()
        cls.server.server_close()

    def fetch(self, path):
        connection = HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            connection.request("GET", path)
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            return response.getheader("Content-Type"), response.read()
        finally:
            connection.close()

    def test_landing_page(self):
        content, body = self.fetch("/")
        self.assertIn("text/html", content)
        self.assertIn(b"<h1>Inventory</h1>", body)

    def test_catalog_fixture(self):
        _, body = self.fetch("/api/catalog")
        self.assertEqual([item["available"] for item in json.loads(body)["items"]], [11, 0])

    def test_control_enabled(self):
        _, body = self.fetch("/ui-config.json")
        self.assertEqual(json.loads(body), {
            "filter_in_stock": scenario == "filter",
            "sort_by_stock": scenario == "sort",
        })

    def test_behavior_module(self):
        content, body = self.fetch("/catalog.js")
        self.assertIn("javascript", content)
        self.assertIn(b'addEventListener("change"', body)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("scenario", choices=["filter", "sort"])
    options, arguments = parser.parse_known_args()
    scenario = options.scenario
    unittest.main(argv=[__file__, *arguments], verbosity=2)
