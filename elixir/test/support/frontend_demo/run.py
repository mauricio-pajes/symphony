#!/usr/bin/env python3
"""Record a verified browser interaction and upload it as private Linear evidence."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE.parent / "bruno_demo"))
from run import git_digest, keychain_login, run, upload, wait_for_api

PORT = 8768


def main():
    workspace, revision, scenario = sys.argv[1:]
    workspace = Path(workspace).resolve()
    shots = json.load(sys.stdin)
    if (not re.fullmatch(r"pilot@[0-9a-f-]{36}", workspace.name)
            or scenario not in {"filter", "sort"} or shots["viewport"] not in {"desktop", "mobile"}
            or shots["hold_seconds"] not in range(4, 9) or git_digest(workspace, "ui-config.json") != revision):
        raise ValueError("The browser demo inputs or revision are invalid.")

    folder = Path.home() / "Downloads" / "Symphony-Stockroom-qa-evidence" / workspace.name.removeprefix("pilot@")
    folder.mkdir(mode=0o700, parents=True, exist_ok=False)
    (folder / "demo-plan.json").write_text(json.dumps(shots, indent=2) + "\n")
    with (folder / "server.log").open("wb") as logs, subprocess.Popen(
        [sys.executable, "-B", "inventory.py", "--port", str(PORT)], cwd=workspace, stdout=logs, stderr=logs,
    ) as server:
        try:
            wait_for_api(server, PORT)
            run("node", str(HERE / "walkthrough.cjs"), f"http://127.0.0.1:{PORT}",
                scenario, shots["viewport"], str(shots["hold_seconds"]), str(folder), timeout=75)
        except subprocess.CalledProcessError as error:
            (folder / "diagnostics.log").write_bytes(error.stderr or b"Browser execution failed.")
            raise
        finally:
            server.terminate()

    if git_digest(workspace, "ui-config.json") != revision:
        raise ValueError("The reviewed frontend changed during recording.")

    video = folder / f"stockroom-{scenario}.mp4"
    run("ffmpeg", "-v", "error", "-i", str(folder / "stockroom.webm"), "-an", "-c:v", "libx264",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(video))
    duration = float(run("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(video)))
    if not 6 <= duration <= 30:
        raise ValueError("The browser demo has an invalid duration.")
    evidence = {"video": upload(video, keychain_login()), "diff_sha256": revision}
    (folder / "linear-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps({"type": "demo", "result": evidence}), flush=True)


if __name__ == "__main__":
    os.umask(0o077)
    main()
