#!/usr/bin/env python3
"""Run Gemini's bounded demo plan in the native Bruno window, then upload the verified takes."""

import hashlib
from http.client import HTTPConnection
import json
import os
from pathlib import Path
import pwd
import re
import select
import shutil
import subprocess
import sys
import time
from urllib.error import HTTPError

API = "http://127.0.0.1:8767"
HERE = Path(__file__).resolve().parent
SCENARIOS = {
    "available": ("NOTEBOOK-01", 200, {"sku": "NOTEBOOK-01", "on_hand": 14, "reserved": 3, "available": 11}),
    "missing": ("MISSING-99", 404, {"error": "item_not_found"}),
}
sys.path.insert(0, str(HERE.parents[2] / "support"))
from linear_video import upload


class BrunoPreparationError(ValueError):
    """The transient request failed before a recording or upload started."""


def run(*args, cwd=None, timeout=20):
    return subprocess.check_output(args, cwd=cwd, timeout=timeout, stderr=subprocess.PIPE)


def git_digest(workspace, source="availability.json"):
    diff = run("git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
               "diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", source, cwd=workspace)
    if not diff:
        raise ValueError("The reviewed API diff is missing.")
    return hashlib.sha256(diff).hexdigest()


def wait_for_api(server, port=8767):
    for _ in range(25):
        if server.poll() is not None:
            break
        connection = HTTPConnection("127.0.0.1", port, timeout=0.5)
        try:
            connection.request("GET", "/api/items")
            if connection.getresponse().status == 200:
                return
        except OSError:
            time.sleep(0.1)
        finally:
            connection.close()
    raise ValueError("The example server could not open its loopback port.")


def copy_tools(directory):
    ui = directory / "bruno-ui"
    recorder = directory / "record"
    run("xcrun", "swiftc", str(HERE / "Bruno.swift"), "-o", str(ui), timeout=35)
    run("xcrun", "swiftc", "-target", "arm64-apple-macosx15.0", "-parse-as-library",
        str(HERE / "Record.swift"), "-o", str(recorder), timeout=35)
    return ui, recorder


def verify_take(ui, file, status, marker):
    media = json.loads(run("ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(file)))
    duration = float(media["format"]["duration"])
    streams = media["streams"]
    if not 7 <= duration <= 30 or len(streams) != 1 or streams[0]["width"] < 900:
        raise ValueError("The capture lacks a usable silent video track.")
    preview = file.with_suffix(".png")
    run("ffmpeg", "-v", "error", "-ss", str(duration - 1.5), "-i", str(file), "-frames:v", "1", str(preview))
    response_crop = file.with_name(file.stem + "-response.png")
    run("ffmpeg", "-v", "error", "-i", str(preview), "-vf", "crop=iw*0.62:ih*0.37:iw*0.38:ih*0.11,hue=s=0",
        "-frames:v", "1", str(response_crop))
    frame = run(str(ui), "ocr", str(preview)).decode().lower()
    response = run(str(ui), "ocr", str(response_crop)).decode().lower()
    words_and_numbers = re.findall(r"[a-z0-9_]+", f"{frame}\n{response}")
    if "availability" not in frame or str(status) not in words_and_numbers or marker not in words_and_numbers:
        raise ValueError("The final recording frame did not show the expected Bruno URL and response.")


def record(ui, recorder, directory, scenario, shots):
    sku, status, payload = SCENARIOS[scenario]
    url = f"{API}/api/items/{sku}/availability"
    marker = "11" if scenario == "available" else "item_not_found"
    # Verify the service separately from the visible client test.
    connection = HTTPConnection("127.0.0.1", 8767, timeout=3)
    try:
        connection.request("GET", urlsplit(url).path)
        response = connection.getresponse()
        if response.status != status or json.load(response) != payload:
            raise ValueError("The example API did not match the demo scenario.")
    finally:
        connection.close()

    file = directory / f"stockroom-{scenario}.mp4"
    stop = directory / f"stop-{scenario}"
    for attempt in range(2):
        try:
            prepare_and_capture(ui, recorder, file, stop, url, status, shots)
            break
        except BrunoPreparationError:
            if attempt:
                raise
            time.sleep(1)
    verify_take(ui, file, status, marker)
    return file


def prepare_and_capture(ui, recorder, file, stop, url, status, shots):
    with subprocess.Popen(
        [str(ui), "shot", url, str(status), shots["emphasis"]],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    ) as shot:
        try:
            ready, _, _ = select.select([shot.stdout], [], [], 12)
            if not ready:
                raise BrunoPreparationError("Bruno did not prepare a transient request.")
            line = shot.stdout.readline()
            if not line:
                error = shot.stderr.read().strip()
                if "the workspace sidebar could not be hidden" in error:
                    raise BrunoPreparationError(error)
                raise ValueError(error or "Bruno closed before recording.")
            capture_shot(recorder, file, stop, json.loads(line), shot, shots["hold_seconds"])
        finally:
            if shot.poll() is None:
                shot.terminate()
                try:
                    shot.wait(3)
                except subprocess.TimeoutExpired:
                    shot.kill()
                    shot.wait()


def capture_shot(recorder, file, stop, target, shot, hold_seconds):
    width, height = target["width"], target["height"]
    if width < 950 or height < 550:
        raise ValueError("Bruno needs a window at least 950x550 points to record the demo.")
    # Crop the title bar and footer. Only capture the Bruno window.
    crop = f"0,70,{width},{height - 98}"
    with subprocess.Popen(
        [str(recorder), str(target["id"]), str(file), str(stop), crop, "23"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    ) as capture:
        try:
            ready, _, _ = select.select([capture.stdout], [], [], 12)
            if not ready or not capture.stdout.readline().startswith("READY "):
                raise ValueError("ScreenCaptureKit could not start recording the Bruno window.")
            time.sleep(1.2)
            shot.stdin.write("recording\n")
            shot.stdin.flush()
            if shot.wait(13):
                raise ValueError(shot.stderr.read().strip() or "Bruno could not send the prepared request.")
            time.sleep(hold_seconds)
        finally:
            stop.touch()
            try:
                capture.wait(13)
            except subprocess.TimeoutExpired:
                capture.terminate()
                capture.wait(5)
        if capture.returncode:
            raise ValueError("The window recording did not finalize.")


def keychain_login():
    account = pwd.getpwuid(os.getuid()).pw_name
    return run("/usr/bin/security", "find-generic-password", "-a", account,
               "-s", "symphony-linear-personal-pilot", "-w").decode().strip()


def main():
    workspace = Path(sys.argv[1]).resolve()
    revision = sys.argv[2]
    shots = json.load(sys.stdin)
    if (not re.fullmatch(r"pilot@[0-9a-f-]{36}", workspace.name)
            or shots["first"] not in SCENARIOS or shots["emphasis"] not in {"status", "body"}
            or shots["hold_seconds"] not in range(4, 9) or git_digest(workspace) != revision):
        raise ValueError("The demo input is outside the approved fixture.")
    directory = Path.home() / "Downloads" / "Symphony-Stockroom-qa-evidence" / workspace.name.removeprefix("pilot@")
    directory.mkdir(parents=True, mode=0o700, exist_ok=False)
    (directory / "demo-plan.json").write_text(json.dumps(shots, indent=2) + "\n")
    diagnostics = directory / "diagnostics.log"
    try:
        ui, recorder = copy_tools(directory)
        with (directory / "server.log").open("wb") as log, subprocess.Popen(
            [sys.executable, "-B", "inventory.py", "--port", "8767"], cwd=workspace, stdout=log, stderr=log,
        ) as server:
            try:
                wait_for_api(server)
                first = shots["first"]
                order = [first, next(scenario for scenario in SCENARIOS if scenario != first)]
                files = {scenario: record(ui, recorder, directory, scenario, shots) for scenario in order}
            finally:
                server.terminate()
                run(str(ui), "restore")
        if git_digest(workspace) != revision:
            raise ValueError("The app source changed during recording.")
        key = keychain_login()
        evidence = {scenario: upload(file, key) for scenario, file in files.items()}
        evidence["diff_sha256"] = revision
        (directory / "linear-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(json.dumps({"type": "demo", "result": evidence}), flush=True)
    except subprocess.CalledProcessError as error:
        diagnostics.write_text(error.stderr.decode(errors="replace")[:4000] if error.stderr else "A local command failed.\n")
        raise
    except (HTTPError, TimeoutError, ValueError, OSError) as error:
        diagnostics.write_text(f"{type(error).__name__}: {getattr(error, 'code', '')}\n" if isinstance(error, HTTPError)
                               else f"{type(error).__name__}: {str(error)}\n")
        raise


if __name__ == "__main__":
    os.umask(0o077)
    main()
