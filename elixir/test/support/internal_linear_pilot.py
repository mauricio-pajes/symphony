#!/usr/bin/env python3
"""Drive the Symphony escript against a local simulation of Linear GraphQL."""

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import URLError
from urllib.request import urlopen


ISSUE = "11111111-1111-4111-8111-111111111111"
TODO = "22222222-2222-4222-8222-222222222222"
REVIEW = "33333333-3333-4333-8333-333333333333"
TEAM = "44444444-4444-4444-8444-444444444444"
PROJECT = "symphony-synthetic"
JIRA = "https://jira.fixture.test/browse/PILOT-1"
ACKNOWLEDGEMENT = "--i-understand-that-this-will-be-running-without-the-usual-guardrails"


class LinearFixture:
    def __init__(self, mode):
        self.lock = threading.Lock()
        self.reads = 0
        self.changes = 0
        self.name = "Todo"
        self.state_id = TODO
        self.mode = mode
        self.unexpected = []
        self.read_blocked = threading.Event()
        self.release_read = threading.Event()

    def request(self, query, variables):
        with self.lock:
            if "query SymphonyPilotIssue" in query and variables == {
                "id": ISSUE, "project": PROJECT, "review": REVIEW,
            }:
                self.reads += 1
                if self.mode == "crash" and self.reads == 2:
                    self.read_blocked.set()
                    self.release_read.wait(15)
                if self.mode == "edited" and self.reads >= 2:
                    title = "Edited during the pilot"
                else:
                    title = "Synthetic Symphony pilot"

                return 200, {"data": {
                    "issues": {"nodes": [{
                        "id": ISSUE,
                        "identifier": "SYMP-1",
                        "title": title,
                        "description": f"[{JIRA}](<{JIRA}>)" if self.mode == "normal" else JIRA,
                        "url": "https://linear.example.test/issue/SYMP-1",
                        "archivedAt": None,
                        "team": {"id": TEAM},
                        "state": {"id": self.state_id, "name": self.name},
                    }]},
                    "workflowState": {"id": REVIEW, "name": "Human Review", "team": {"id": TEAM}},
                }}

            if "mutation SymphonyPilotHumanReview" in query and variables == {"id": ISSUE, "stateId": REVIEW}:
                self.changes += 1
                if self.mode == "lost-ack-active":
                    return 503, {"errors": [{"message": "Mock acknowledgement lost without applying mutation"}]}
                self.name, self.state_id = "Human Review", REVIEW
                if self.mode == "lost-ack-applied":
                    return 503, {"errors": [{"message": "Mock acknowledgement lost after applying mutation"}]}
                return 200, {"data": {"issueUpdate": {
                    "success": True,
                    "issue": {"id": ISSUE, "state": {"id": REVIEW, "name": "Human Review"}},
                }}}

            self.unexpected.append(query.splitlines()[0])
            return 400, {"errors": [{"message": "Unexpected query or scope"}]}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/graphql" or self.headers.get("Authorization") != "fixture-token":
            self.send_error(403)
            return
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        status, body = self.server.fixture.request(request["query"], request["variables"])
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass

    def log_message(self, *_args):
        pass


def daemon_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def write_workflow(root, server, args):
    workspace = root / "workspaces"
    journal = root / "state"
    workspace.mkdir()
    journal.mkdir(mode=0o700)
    workflow = root / "WORKFLOW.md"
    workflow.write_text(f"""---
tracker:
  kind: linear
  endpoint: http://127.0.0.1:{server.server_port}/graphql
  api_key: fixture-token
  project_slug: {PROJECT}
  active_states: [Todo]
  terminal_states: [Done, Canceled]
polling:
  interval_ms: 200
workspace:
  root: {json.dumps(str(workspace))}
agent:
  internal_pilot:
    issue_id: "{ISSUE}"
    human_review_state_id: "{REVIEW}"
    state_directory: {json.dumps(str(journal))}
    docker_socket: {json.dumps(args.socket)}
    image: {json.dumps(args.image)}
observability:
  dashboard_enabled: false
---
Synthetic internal pilot.
""")
    return workflow


def start_daemon(binary, workflow, port, log):
    with log.open("a") as output:
        return subprocess.Popen(
            [str(binary), ACKNOWLEDGEMENT, "--port", str(port), "--logs-root", str(log.parent / "logs"), str(workflow)],
            cwd=workflow.parent,
            stdout=output,
            stderr=subprocess.STDOUT,
            env={**os.environ, "ERL_FLAGS": "+S 4:4 +SDcpu 2 +SDio 2"},
        )


def stop_daemon(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def await_blocked(daemon, port, reasons, state):
    if isinstance(reasons, str):
        reasons = (reasons,)
    deadline = time.monotonic() + 25
    snapshot = {}
    while time.monotonic() < deadline and daemon.poll() is None:
        try:
            with urlopen(f"http://127.0.0.1:{port}/api/v1/state", timeout=2) as response:
                snapshot = json.load(response)
        except (URLError, TimeoutError):
            pass
        for entry in snapshot.get("blocked", []):
            if entry["issue_id"] == ISSUE and entry["state"] == state and entry["error"] in reasons:
                assert snapshot["counts"]["running"] == 0, snapshot
                return entry
        time.sleep(0.12)
    raise AssertionError(f"daemon did not publish expected state {state!r}/{reasons!r}: {snapshot}")


def daemon_logs(log):
    rotated = sorted((log.parent / "logs" / "log").glob("symphony.log.[0-9]*"))
    return "\n".join(path.read_text(errors="replace") for path in [log, *rotated] if path.exists())


def run_case(args, mode):
    with tempfile.TemporaryDirectory(prefix="symphony-linear-pilot-") as temporary:
        root = Path(temporary)
        log = root / "daemon.log"
        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            server.fixture = LinearFixture(mode)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                verify = verify_crash if mode == "crash" else verify_case
                verify(args, mode, root, server, log)
            except Exception:
                if log.exists():
                    print(daemon_logs(log))
                raise
            finally:
                server.shutdown()
                thread.join()


def verify_case(args, mode, root, server, log):
    workflow = write_workflow(root, server, args)
    port = daemon_port()
    reason, state, mutations, generation = {
        "normal": ("human review", "Human Review", 1, 4),
        "lost-ack-applied": ("human review", "Human Review", 1, 4),
        "lost-ack-active": ("pilot review transition unconfirmed", "Todo", 1, 4),
        "edited": (("pilot worker settlement blocked", "pilot issue changed"), "Todo", 0, 1),
    }[mode]
    daemon = start_daemon(args.binary, workflow, port, log)
    try:
        blocked = await_blocked(daemon, port, reason, state)
    finally:
        stop_daemon(daemon)

    ledger = json.loads((root / "state" / "admission.json").read_text())
    [record] = ledger["records"]
    expected_disposition = {"Human Review": "human_review", "Todo": "review_pending"}[state]
    if mode == "edited":
        expected_disposition = "parked"
    assert record["status"] == expected_disposition and record["generation"] == generation and record["lease"] is None, record

    if generation == 4:
        assert (root / "workspaces" / ("pilot@" + ISSUE) / "result.txt").read_text() == "fixture-response\n"
    daemon_output = daemon_logs(log)
    assert "read simulated Jira requirements key=PILOT-1" in daemon_output, daemon_output
    assert daemon_output.count("started phase=") == generation

    restarted = start_daemon(args.binary, workflow, port, log)
    try:
        after_restart = "pilot parked after restart" if mode == "edited" else reason
        await_blocked(restarted, port, after_restart, state)
    finally:
        stop_daemon(restarted)

    assert not server.fixture.unexpected, server.fixture.unexpected
    assert server.fixture.changes == mutations, server.fixture.changes
    assert daemon_logs(log).count("started phase=") == generation
    print(f"{mode}: SYMP-1 -> {blocked['state']} ({blocked['error']}); "
          f"{generation} phase starts, {mutations} mutation request(s), durable across restart")
    if mode == "normal":
        for line in daemon_output.splitlines():
            if "Internal pilot" in line:
                print(line)


def verify_crash(args, _mode, root, server, log):
    workflow = write_workflow(root, server, args)
    port = daemon_port()
    daemon = start_daemon(args.binary, workflow, port, log)
    ledger = root / "state" / "admission.json"
    try:
        assert server.fixture.read_blocked.wait(20), daemon_logs(log)
        [record] = json.loads(ledger.read_text())["records"]
        assert record["lease"]["process_identity"].startswith("docker:"), record
        daemon.kill()
        daemon.wait(5)
    finally:
        server.fixture.release_read.set()
        stop_daemon(daemon)

    restarted = start_daemon(args.binary, workflow, port, log)
    try:
        await_blocked(restarted, port, "pilot parked after restart", "Todo")
    finally:
        stop_daemon(restarted)

    [record] = json.loads(ledger.read_text())["records"]
    assert record["status"] == "parked" and record["generation"] == 1 and record["lease"] is None, record
    assert server.fixture.changes == 0
    assert not server.fixture.unexpected, server.fixture.unexpected
    print("crash: attached worker drained after BEAM restart; generation 1 parked, no transition")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path("bin/symphony"))
    parser.add_argument("--socket", required=True)
    parser.add_argument("--image", required=True)
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    for mode in ("normal", "lost-ack-applied", "lost-ack-active", "edited", "crash"):
        run_case(args, mode)


if __name__ == "__main__":
    main()
