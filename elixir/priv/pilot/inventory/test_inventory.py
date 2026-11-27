"""Fixed HTTP contract tests for the availability change."""

from http.client import HTTPConnection
import json
from threading import Thread
import unittest

from inventory import build_server


class AvailabilityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = build_server(0, quiet=True)
        cls.worker = Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.worker.join()
        cls.server.server_close()

    def get(self, path):
        connection = HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            connection.request("GET", path)
            response = connection.getresponse()
            self.assertEqual(response.getheader("Content-Type"), "application/json")
            return response.status, json.load(response)
        finally:
            connection.close()

    def test_available_stock(self):
        self.assertEqual(self.get("/api/items/NOTEBOOK-01/availability"), (
            200, {"sku": "NOTEBOOK-01", "on_hand": 14, "reserved": 3, "available": 11}
        ))

    def test_fully_reserved_stock(self):
        self.assertEqual(self.get("/api/items/PENCIL-02/availability"), (
            200, {"sku": "PENCIL-02", "on_hand": 4, "reserved": 4, "available": 0}
        ))

    def test_unknown_sku(self):
        self.assertEqual(self.get("/api/items/MISSING-99/availability"), (404, {"error": "item_not_found"}))

    def test_existing_item_list(self):
        self.assertEqual(self.get("/api/items"), (200, {"items": [
            {"sku": "NOTEBOOK-01", "name": "Field notebook"},
            {"sku": "PENCIL-02", "name": "Graphite pencil"},
        ]}))


if __name__ == "__main__":
    unittest.main(verbosity=2)
