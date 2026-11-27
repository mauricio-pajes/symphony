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
from urllib.parse import urlsplit
from urllib.request import Request, HTTPRedirectHandler, build_opener

API = "http://127.0.0.1:8767"
LINEAR = "https://api.linear.app/graphql"
HERE = Path(__file__).resolve().parent
SCENARIOS = {
    "available": ("NOTEBOOK-01", 200, {"sku": "NOTEBOOK-01", "on_hand": 14, "reserved": 3, "available": 11}),
    "missing": ("MISSING-99", 404, {"error": "item_not_found"}),
}
UPLOAD = """
mutation StockroomDemoUpload($filename: String!, $size: Int!) {
  fileUpload(filename: $filename, contentType: "video/mp4", size: $size, makePublic: false) {
    success
    uploadFile { uploadUrl assetUrl headers { key value } }
  }
}
"""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


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
    with subprocess.Popen(
        [str(ui), "shot", url, str(status), shots["emphasis"]],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    ) as shot:
        try:
            ready, _, _ = select.select([shot.stdout], [], [], 12)
            if not ready:
                raise ValueError("Bruno did not prepare a transient request.")
            line = shot.stdout.readline()
            if not line:
                raise ValueError(shot.stderr.read().strip() or "Bruno closed before recording.")
            capture_shot(recorder, file, stop, json.loads(line), shot, shots["hold_seconds"])
        finally:
            if shot.poll() is None:
                shot.terminate()
    verify_take(ui, file, status, marker)
    return file


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


def https_url(value):
    parsed = urlsplit(value)
    return parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username and not parsed.password


def keychain_login():
    account = pwd.getpwuid(os.getuid()).pw_name
    return run("/usr/bin/security", "find-generic-password", "-a", account,
               "-s", "symphony-linear-personal-pilot", "-w").decode().strip()


def upload(file, key):
    opener = build_opener(NoRedirect())
    body = json.dumps({"query": UPLOAD, "variables": {"filename": file.name, "size": file.stat().st_size}}).encode()
    with opener.open(Request(LINEAR, data=body, headers={
        "Authorization": key, "Content-Type": "application/json"
    }, method="POST"), timeout=12) as response:
        data = json.load(response)
    payload = data.get("data", {}).get("fileUpload")
    if not payload or not payload.get("success"):
        raise ValueError("Linear declined the private video upload.")

    upload_file = payload["uploadFile"]
    asset, signed = upload_file["assetUrl"], upload_file["uploadUrl"]
    if not https_url(signed) or not re.fullmatch(r"https://uploads\.linear\.app/[-/a-zA-Z0-9_]+(?:\.mp4)?", asset):
        raise ValueError("Linear returned an unexpected video location.")
    headers = {header["key"]: header["value"] for header in (upload_file["headers"] or [])}
    headers.setdefault("Content-Type", "video/mp4")
    video = file.read_bytes()
    with opener.open(Request(signed, data=video, headers=headers, method="PUT"), timeout=22) as response:
        if response.status not in range(200, 300):
            raise ValueError("The private video upload failed.")

    # Fetch the same private bytes back. Never forward the API key to a redirect.
    try:
        request = Request(asset, headers={"Authorization": key})
        with opener.open(request, timeout=12) as fetched:
            downloaded = fetched.read(len(video) + 1)
    except HTTPError as error:
        location = error.headers.get("Location", "")
        if error.code not in [301, 302, 307, 308] or not https_url(location):
            raise ValueError(f"Linear could not read back the private upload (HTTP {error.code}).") from None
        with opener.open(location, timeout=12) as fetched:
            downloaded = fetched.read(len(video) + 1)
    if hashlib.sha256(downloaded).digest() != hashlib.sha256(video).digest():
        raise ValueError("The private Linear asset differs from the verified recording.")
    return asset


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
