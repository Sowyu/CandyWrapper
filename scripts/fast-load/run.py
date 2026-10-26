#!/usr/bin/env python3
"""Runs the headless CandyWrapper benchmark. Sandbox credentials stay in memory."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import urllib.parse
import urllib.request

BASE = Path.home() / "CandyWrapper-research/sandbox/fast-load"


def clean_environment():
    return {"HOME": str(Path.home()), "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8", "T3CODE_TELEMETRY_ENABLED": "false"}


def token(name):
    port = {"3473": 47441, "main": 47442}[name]
    if name == "3473":
        command = [str(Path.home() / "CandyWrapper-research/runtimes/t3-0.1.2-nightly.20261021.3473-darwin-arm64/t3")]
    else:
        command = ["/opt/homebrew/bin/node", str(BASE / "source-main/apps/server/src/bin.ts")]
    result = subprocess.run(command + ["auth", "pairing", "create", "--base-dir", str(BASE / name / "t3home"),
                                      "--label", "Fast load sandbox", "--json"],
                            env=clean_environment(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90, check=True)
    output = result.stdout.decode()
    grant = json.loads(output[output.index("{"):output.rindex("}") + 1])["credential"]
    body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token": grant,
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "subject_token_type": "urn:t3:params:oauth:token-type:environment-bootstrap",
        "client_label": "Fast load sandbox", "client_device_type": "desktop", "client_os": "macOS"
    }).encode()
    request = urllib.request.Request("http://127.0.0.1:%d/oauth/token" % port, body,
                                     {"Content-Type": "application/x-www-form-urlencoded", "X-T3-Orchestration-Protocol": "2"})
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)["access_token"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("server", choices=["3473", "main"])
    parser.add_argument("--binary")
    parser.add_argument("--label", default="fast-load")
    parser.add_argument("--token-file", help="Create the explicitly requested temporary UI grant inside this server's fast-load home")
    parser.add_argument("--timeout", type=int, default=400)
    args = parser.parse_args()
    if args.token_file:
        path = Path(args.token_file).expanduser().resolve()
        if path.parent != BASE / args.server or path.name not in ["session.token", "ui.token"]:
            parser.error("UI grants are allowed only at the isolated server's session.token or ui.token path")
        credential = token(args.server)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(credential + "\n")
        print("Created temporary isolated sandbox UI grant:", path)
        raise SystemExit(0)
    if not args.binary:
        parser.error("--binary is required for a benchmark")
    config = {"port": {"3473": 47541, "main": 47542}[args.server], "token": token(args.server),
              "threadId": "fast-load-big-thread", "label": args.label}
    result = subprocess.run([args.binary], input=json.dumps(config).encode(), stdout=subprocess.PIPE,
                            check=True, timeout=args.timeout)
    print(result.stdout.decode(), end="", flush=True)
    values = [json.loads(line) for line in result.stdout.decode().splitlines() if line.startswith("{")]
    timed = [value for value in values if value["phase"] in ["cold", "retained-reconnect"]]
    if len(timed) != 2 or any(not value["synchronized"] or value["failure"] for value in timed):
        raise RuntimeError("Client did not synchronize both timed phases")
    if timed[0]["content"] != timed[1]["content"] or timed[0]["shell_threads"] != timed[1]["shell_threads"]:
        raise RuntimeError("Retained reconnect changed restored content")
    validation = next(value for value in values if value["phase"] == "history-validation")["content"]
    expected = next(json.loads(line) for line in (BASE / "dataset.jsonl").read_text().splitlines()
                    if json.loads(line)["server"] == args.server)
    if validation["visible_message_items"] != expected["messages"] or validation["blank_visible_message_items"]:
        raise RuntimeError("History contains missing or blank message bodies")
    if validation["visible_items"] != expected["turn_items"]:
        raise RuntimeError("History is missing timeline rows")
    if validation["full_visible_message_sha256"] != expected["full_visible_message_sha256"]:
        raise RuntimeError("Fully paged message bodies differ from the synthetic source")
