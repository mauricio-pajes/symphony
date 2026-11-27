"""Small loopback inventory service for the Symphony example project."""

import argparse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import sqlite3
from urllib.parse import urlsplit

ROOT = Path(__file__).parent
ITEMS = [
    ("NOTEBOOK-01", "Field notebook", 14, 3),
    ("PENCIL-02", "Graphite pencil", 4, 4),
]


def inventory(sku=None):
    with sqlite3.connect(":memory:") as db:
        db.row_factory = sqlite3.Row
        db.execute("CREATE TABLE item (sku TEXT PRIMARY KEY, name TEXT, on_hand INT, reserved INT)")
        db.executemany("INSERT INTO item VALUES (?, ?, ?, ?)", ITEMS)
        if sku is None:
            return [dict(row) for row in db.execute("SELECT sku, name FROM item ORDER BY sku")]
        row = db.execute("SELECT * FROM item WHERE sku = ?", (sku,)).fetchone()
        return dict(row) if row else None


def build_server(port, *, quiet=False):
    route = json.loads((ROOT / "availability.json").read_text())["route"]

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlsplit(self.path).path
            if path == "/api/items":
                self.send_json(HTTPStatus.OK, {"items": inventory()})
                return
            match = re.fullmatch(route["path"].replace("{sku}", "([A-Z0-9-]+)"), path) if route else None
            if match and route["method"] == "GET":
                item = inventory(match[1])
                if item is None:
                    self.send_json(HTTPStatus.NOT_FOUND, {"error": route["not_found"]})
                    return
                item["available"] = max(0, item["on_hand"] - item["reserved"])
                self.send_json(HTTPStatus.OK, {field: item[field] for field in route["fields"]})
                return
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "route_not_found"})

        def send_json(self, status, payload):
            body = (json.dumps(payload) + "\n").encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            if not quiet:
                super().log_message(fmt, *args)

    return ThreadingHTTPServer(("127.0.0.1", port), Handler)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8767)
    args = parser.parse_args()
    with build_server(args.port) as server:
        print(f"Inventory API on http://127.0.0.1:{server.server_port}", flush=True)
        server.serve_forever()
