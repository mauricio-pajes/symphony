#!/usr/bin/env python3
"""Drive the Symphony escript against a local simulation of Linear GraphQL."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
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
CODEX_JIRA = "https://jira.fixture.test/browse/PILOT-2"
MULTI_JIRA = "https://jira.fixture.test/browse/PILOT-3"
API_JIRA = "https://jira.fixture.test/browse/PILOT-4"
API_ROUTE = {"route": {
    "method": "GET", "path": "/api/items/{sku}/availability",
    "fields": ["sku", "on_hand", "reserved", "available"], "not_found": "item_not_found",
}}
PLAN = "Trim surrounding horizontal whitespace and preserve ASCII normalization."
REVIEW_SUMMARY = "The revision matches all three acceptance criteria."
VERSION_NORMALIZER = (
    "y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/\n"
    "s/^[[:blank:]]*//\n"
    "s/[[:blank:]]*$//\n"
)
ACKNOWLEDGEMENT = "--i-understand-that-this-will-be-running-without-the-usual-guardrails"


class LinearFixture:
    def __init__(self, mode):
        self.lock = threading.Lock()
        self.reads = 0
        self.changes = 0
        self.name = "Todo"
        self.state_id = TODO
        self.mode = mode
        self.queue = mode in ("queue", "queue-crash", "queue-retry")
        self.api = self.queue or mode in ("api", "api-demo-failed")
        self.multi = self.api or mode in ("multi", "multi-rejected")
        self.repository = self.multi or mode in ("codex", "codex-invalid")
        self.jira = API_JIRA if self.api else MULTI_JIRA if self.multi else CODEX_JIRA if self.repository else JIRA
        self.description = self.jira
        if mode == "normal":
            self.description = f"[{JIRA}](<{JIRA}>)"
        self.unexpected = []
        self.read_blocked = threading.Event()
        self.release_read = threading.Event()
        self.queue_polled = threading.Event()
        self.queue_add = threading.Event()
        self.ledger_path = None
        self.review_read_failed = False

    def request(self, query, variables):
        with self.lock:
            if self.queue and "query SymphonyLinearPoll" in query and variables["projectSlug"] == PROJECT:
                self.queue_polled.set()
                candidates = [self.queue_node("55555555-5555-4555-8555-555555555555", "2025-12-30T00:00:00Z")]
                if self.queue_add.is_set() and self.state_id == TODO:
                    candidates.append(self.queue_node(ISSUE, "2026-01-02T00:00:00Z"))
                return 200, {"data": {"issues": {"nodes": candidates, "pageInfo": {"hasNextPage": False}}}}
            if "query SymphonyPilotIssue" in query and variables == {
                "id": ISSUE, "project": PROJECT, "review": REVIEW,
            }:
                self.reads += 1
                if self.mode == "queue-retry" and self.state_id == REVIEW and not self.review_read_failed:
                    self.review_read_failed = True
                    return 503, {"errors": [{"message": "Review observation temporarily unavailable"}]}
                if self.block_read_for_crash():
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
                        "description": self.description,
                        "url": "https://linear.example.test/issue/SYMP-1",
                        "archivedAt": None,
                        "team": {"id": TEAM},
                        "state": {"id": self.state_id, "name": self.name},
                    }]},
                    "workflowState": {"id": REVIEW, "name": "Human Review", "team": {"id": TEAM}},
                }}

            expected = {"id": ISSUE, "stateId": REVIEW}
            if self.repository:
                description = variables.get("description", "")
                if (description.startswith(self.jira) and "### Symphony pilot evidence" in description
                        and "Offline checks passed (4/4)" in description):
                    expected["description"] = description
            if "mutation SymphonyPilotHumanReview" in query and variables == expected:
                self.changes += 1
                if self.mode == "lost-ack-active":
                    return 503, {"errors": [{"message": "Mock acknowledgement lost without applying mutation"}]}
                self.name, self.state_id = "Human Review", REVIEW
                self.description = variables.get("description", self.description)
                if self.mode == "lost-ack-applied":
                    return 503, {"errors": [{"message": "Mock acknowledgement lost after applying mutation"}]}
                return 200, {"data": {"issueUpdate": {
                    "success": True,
                    "issue": {"id": ISSUE, "state": {"id": REVIEW, "name": "Human Review"}},
                }}}

            self.unexpected.append(query.splitlines()[0])
            return 400, {"errors": [{"message": "Unexpected query or scope"}]}

    def queue_node(self, issue, created):
        return {"id": issue, "identifier": "SYMP-1", "title": "Synthetic Symphony pilot",
                "description": self.jira, "state": {"name": "Todo"}, "createdAt": created,
                "url": "https://linear.example.test/issue/SYMP-1", "inverseRelations": {"nodes": []}}

    def block_read_for_crash(self):
        if self.mode == "crash":
            return self.reads == 2
        if self.mode != "queue-crash" or self.read_blocked.is_set() or not self.ledger_path.exists():
            return False
        records = json.loads(self.ledger_path.read_text())["records"]
        return any((record["lease"] or {}).get("process_identity") for record in records)


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
    implementation = ""
    if server.fixture.repository:
        mode = "api_demo" if server.fixture.api else "multi_agent" if server.fixture.multi else "codex"
        implementation = f"    implementation: {mode}\n"
    image = args.image
    if server.fixture.api:
        implementation += f"    demo_runner: {json.dumps(str(root / 'bin' / 'bruno-demo'))}\n"
        image = args.api_image
    scope = f'    issue_id: "{ISSUE}"\n'
    if server.fixture.queue:
        implementation = f'''    implementation: queue
    demo_runner: {json.dumps(str(root / 'bin' / 'bruno-demo'))}
    frontend_runner: {json.dumps(str(root / 'bin' / 'bruno-demo'))}
    queue_since: "2026-01-01T00:00:00Z"
'''
        scope = ""
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
{implementation}{scope}    human_review_state_id: "{REVIEW}"
    state_directory: {json.dumps(str(journal))}
    docker_socket: {json.dumps(args.socket)}
    image: {json.dumps(image)}
observability:
  dashboard_enabled: false
---
Synthetic internal pilot.
""")
    return workflow


def start_daemon(binary, workflow, port, log):
    env = {**os.environ, "ERL_FLAGS": "+S 4:4 +SDcpu 2 +SDio 2", "LINEAR_API_KEY": "must-not-reach-provider"}
    local_bin = workflow.parent / "bin"
    if local_bin.is_dir():
        env["PATH"] = os.pathsep.join([str(local_bin), env["PATH"]])
    with log.open("a") as output:
        return subprocess.Popen(
            [str(binary), ACKNOWLEDGEMENT, "--port", str(port), "--logs-root", str(log.parent / "logs"), str(workflow)],
            cwd=workflow.parent,
            stdout=output,
            stderr=subprocess.STDOUT,
            env=env,
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
                verify = {"crash": verify_crash, "queue-crash": verify_crash, "queue": verify_queue,
                          "queue-retry": verify_queue}.get(mode, verify_case)
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
    if server.fixture.repository:
        write_provider_stubs(root, mode)
    port = daemon_port()
    reason, state, mutations, generation = {
        "normal": ("human review", "Human Review", 1, 4),
        "codex": ("human review", "Human Review", 1, 3),
        "codex-invalid": ("codex pilot invalid proposal", "Todo", 0, 1),
        "multi": ("human review", "Human Review", 1, 4),
        "multi-rejected": ("claude pilot changes requested", "Todo", 0, 3),
        "api": ("human review", "Human Review", 1, 4),
        "api-demo-failed": ("pilot bruno demo failed", "Todo", 0, 4),
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
    parked = mode in ("edited", "codex-invalid", "multi-rejected")
    if parked:
        expected_disposition = "parked"
    assert record["status"] == expected_disposition and record["generation"] == generation and record["lease"] is None, record

    workspace = root / "workspaces" / ("pilot@" + ISSUE)
    if generation == 4 and not server.fixture.repository:
        assert (workspace / "result.txt").read_text() == "fixture-response\n"
    daemon_output = daemon_logs(log)
    expected_key = server.fixture.jira.rsplit("/", 1)[1]
    assert f"read simulated Jira requirements key={expected_key}" in daemon_output, daemon_output
    assert daemon_output.count("started phase=") == generation
    if mode in ("codex", "multi"):
        assert "received bounded Codex proposal" in daemon_output, daemon_output
        assert (workspace / "normalize.sed").read_text() == VERSION_NORMALIZER
        diff = subprocess.check_output(["git", "diff", "--no-ext-diff", "--no-textconv", "HEAD"], cwd=workspace)
        assert diff.decode().rstrip() in server.fixture.description
        revision = hashlib.sha256(diff).hexdigest()
        assert f"Diff SHA-256: {revision}" in server.fixture.description
        if mode == "multi":
            assert f"Gemini plan: `{PLAN}`" in server.fixture.description
            assert f"Gemini plan SHA-256: {hashlib.sha256(PLAN.encode()).hexdigest()}" in server.fixture.description
            assert f"Claude Code review: `{REVIEW_SUMMARY}`" in server.fixture.description
            assert f"Claude Code approved diff SHA-256: {revision}" in server.fixture.description
    elif mode == "codex-invalid":
        assert (workspace / "normalize.sed").read_text() == VERSION_NORMALIZER.splitlines(keepends=True)[0]
        assert not (workspace / "artifact.log").exists()
    elif server.fixture.api:
        assert json.loads((workspace / "availability.json").read_text()) == API_ROUTE
        assert daemon_output.count("provider=gemini phase=demo client=bruno") == 1
        if mode == "api":
            assert "### Bruno API demos" in server.fixture.description
            assert "https://uploads.linear.app/fixture/available.mp4" in server.fixture.description
            assert "https://uploads.linear.app/fixture/missing.mp4" in server.fixture.description
            assert "curl -i http://127.0.0.1:8767/api/items/NOTEBOOK-01/availability" in server.fixture.description

    restarted = start_daemon(args.binary, workflow, port, log)
    try:
        after_restart = "pilot parked after restart" if parked else reason
        if mode == "api-demo-failed":
            after_restart = "pilot review transition unconfirmed"
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


def write_provider_stubs(root, mode):
    binary_dir = root / "bin"
    binary_dir.mkdir()
    api = mode.startswith(("api", "queue"))
    source = VERSION_NORMALIZER + "w artifact.log\n" if mode == "codex-invalid" else VERSION_NORMALIZER
    if api:
        source = json.dumps(API_ROUTE, indent=2) + "\n"
    codex_result = {"type": "item.completed", "item": {
        "type": "agent_message", "text": json.dumps({"source": source}),
    }}
    multi = api or mode.startswith("multi")
    write_provider_stub(binary_dir / "codex", PLAN if multi else "Acceptance criteria:", codex_result)
    if multi:
        plan_result = {"event": "result", "result": {
            "status": "SUCCESS", "structured_output": {"summary": PLAN},
        }}
        if api:
            write_api_stubs(binary_dir, plan_result, mode)
        else:
            write_provider_stub(binary_dir / "agy", "Plan a change", plan_result)
        verdict = "changes_requested" if mode == "multi-rejected" else "approved"
        file = "availability.json" if api else "normalize.sed"
        write_provider_stub(binary_dir / "claude", f"diff --git a/{file} b/{file}", {
            "type": "result", "is_error": False, "structured_output": {"verdict": verdict, "summary": REVIEW_SUMMARY},
        })


def write_api_stubs(binary_dir, plan_result, mode):
    demo_result = {"event": "result", "result": {"status": "SUCCESS", "structured_output": {
        "first": "missing", "emphasis": "body", "hold_seconds": 5,
    }}}
    first_invalid_plan = ""
    if mode == "queue-retry":
        marker = shlex.quote(str(binary_dir / "invalid-plan-observed"))
        invalid = {"event": "result", "result": {"status": "SUCCESS", "structured_output": {"summary": ""}}}
        first_invalid_plan = f"""  if [ ! -f {marker} ]; then
    touch {marker}
    printf '%s\\n' {shlex.quote(json.dumps(invalid))}
    exit 0
  fi
"""
    agy = binary_dir / "agy"
    agy.write_text(f"""#!/bin/sh
set -eu
test -z "${{LINEAR_API_KEY-}}"
if grep -Fq 'actual Bruno API client'; then
  printf '%s\\n' {shlex.quote(json.dumps(demo_result))}
else
{first_invalid_plan}  printf '%s\\n' {shlex.quote(json.dumps(plan_result))}
fi
""")
    agy.chmod(0o700)
    outcome = "exit 7" if mode == "api-demo-failed" else r'''printf '{"type":"demo","result":{"diff_sha256":"%s","available":"https://uploads.linear.app/fixture/available.mp4","missing":"https://uploads.linear.app/fixture/missing.mp4"}}\n' "$2"'''
    demo = binary_dir / "bruno-demo"
    demo.write_text(f"""#!/bin/sh
set -eu
test -z "${{LINEAR_API_KEY-}}"
test -f "$1/availability.json"
grep -Fq '"first":"missing"'
{outcome}
""")
    demo.chmod(0o700)


def write_provider_stub(path, expected_prompt, result):
    path.write_text(f"""#!/bin/sh
set -eu
test -z "${{LINEAR_API_KEY-}}"
test ! -e normalize.sed
grep -Fq {shlex.quote(expected_prompt)}
printf '%s\\n' {shlex.quote(json.dumps(result))}
""")
    path.chmod(0o700)


def verify_crash(args, mode, root, server, log):
    workflow = write_workflow(root, server, args)
    if server.fixture.queue:
        write_provider_stubs(root, mode)
    ledger = root / "state" / "admission.json"
    server.fixture.ledger_path = ledger
    port = daemon_port()
    daemon = start_daemon(args.binary, workflow, port, log)
    try:
        if server.fixture.queue:
            assert server.fixture.queue_polled.wait(12)
            server.fixture.queue_add.set()
        assert server.fixture.read_blocked.wait(20), daemon_logs(log)
        [record] = json.loads(ledger.read_text())["records"]
        assert record["lease"]["process_identity"].startswith("docker:"), record
        daemon.kill()
        daemon.wait(5)
    finally:
        server.fixture.release_read.set()
        stop_daemon(daemon)

    server.fixture.queue_polled.clear()
    restarted = start_daemon(args.binary, workflow, port, log)
    try:
        if server.fixture.queue:
            assert server.fixture.queue_polled.wait(12)
            time.sleep(0.6)
            assert daemon_logs(log).count("started phase=") == 1
        else:
            await_blocked(restarted, port, "pilot parked after restart", "Todo")
    finally:
        stop_daemon(restarted)

    [record] = json.loads(ledger.read_text())["records"]
    assert record["status"] == "parked" and record["generation"] == 1 and record["lease"] is None, record
    assert server.fixture.changes == 0
    assert not server.fixture.unexpected, server.fixture.unexpected
    print(f"{mode}: attached worker drained after BEAM restart; generation 1 parked, no transition")


def verify_queue(args, mode, root, server, log):
    fixture = server.fixture
    workflow = write_workflow(root, server, args)
    write_provider_stubs(root, mode)
    port = daemon_port()
    daemon = start_daemon(args.binary, workflow, port, log)
    try:
        assert fixture.queue_polled.wait(12)
        fixture.queue_add.set()
        if mode == "queue-retry":
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                with urlopen(f"http://127.0.0.1:{port}/api/v1/state", timeout=2) as response:
                    snapshot = json.load(response)
                if snapshot["retrying"]:
                    [retry] = snapshot["retrying"]
                    assert retry["issue_id"] == ISSUE and retry["attempt"] == 1, retry
                    assert retry["due_at"] > snapshot["generated_at"], retry
                    break
                time.sleep(0.1)
            else:
                raise AssertionError("The failed planner did not expose a retry for the original ticket")
        await_blocked(daemon, port, "human review", "Human Review")
        assert "### Bruno API demos" in fixture.description
        if mode == "queue-retry":
            assert fixture.review_read_failed
            logs = daemon_logs(log)
            assert logs.count("started authenticated provider=gemini phase=planning") == 2
            assert logs.count("started authenticated provider=gemini phase=demo") == 1
    finally:
        stop_daemon(daemon)
    ledger = json.loads((root / "state" / "admission.json").read_text())
    [record] = ledger["records"]
    assert record["issue_id"] == ISSUE and record["status"] == "human_review" and record["generation"] == 4

    fixture.queue_polled.clear()
    fixture.name, fixture.state_id = "Todo", TODO
    restarted = start_daemon(args.binary, workflow, port, log)
    try:
        assert fixture.queue_polled.wait(12)
        time.sleep(0.7)
        assert fixture.changes == 1 and not fixture.unexpected, fixture.unexpected
        assert daemon_logs(log).count("started phase=") == 4
    finally:
        stop_daemon(restarted)
    print("queue: admitted a new Todo issue after startup, skipped pre-cutover work and did not replay after restart")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path("bin/symphony"))
    parser.add_argument("--socket", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--api-image", help="Optional pinned Python image for the API demo cases")
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    for mode in ("normal", "codex", "codex-invalid", "multi", "multi-rejected", "lost-ack-applied", "lost-ack-active", "edited", "crash"):
        run_case(args, mode)
    if args.api_image:
        for mode in ("api", "api-demo-failed", "queue", "queue-crash", "queue-retry"):
            run_case(args, mode)


if __name__ == "__main__":
    main()
