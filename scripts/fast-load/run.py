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
    parser.add_argument("--binary", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--timeout", type=int, default=400)
    args = parser.parse_args()
    config = {"port": {"3473": 47541, "main": 47542}[args.server], "token": token(args.server),
              "threadId": "fast-load-big-thread", "label": args.label}
    subprocess.run([args.binary], input=json.dumps(config).encode(), check=True, timeout=args.timeout)
