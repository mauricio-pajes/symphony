# Stockroom inventory API

A local example service built with Python 3.12, SQLite and the standard HTTP
library. The baseline serves a catalog. The Symphony PILOT-4 issue adds a
separate availability contract that integrations can use without expanding
the catalog response.

Run the generated project with `python3 -B inventory.py`. The server listens
only on loopback and has no external dependencies or credentials.

```sh
curl -i http://127.0.0.1:8767/api/items
curl -i http://127.0.0.1:8767/api/items/NOTEBOOK-01/availability
curl -i http://127.0.0.1:8767/api/items/MISSING-99/availability
python3 -B test_inventory.py
```
