#!/usr/bin/env python3
"""Wait for a quiet compiler window, then run all four real-client/server cells."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import time
import os
import signal

from run import BASE


def builders():
    rows = subprocess.check_output(["ps", "-axo", "pid=,stat=,comm="], text=True)
    names = {"swift-frontend", "swift-build", "swift-test", "swiftc", "xcodebuild",
             "clang", "clang++", "ld", "xctest", "swiftpm-testing-helper", "CandyKitPackageTests"}
    return ["%s %s %s" % (line.split()[0], line.split()[1], Path(line.split()[-1]).name)
            for line in rows.splitlines()
            if len(line.split()) >= 3 and not line.split()[1].startswith("Z")
            and Path(line.split()[-1]).name in names]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--output", default=str(BASE / "matrix.jsonl"))
    args = parser.parse_args()
    deadline = time.monotonic() + 1800
    stable = 0
    print("Waiting for compiler/test processes to be quiet", flush=True)
    while stable < 3:
        active = builders()
        stable = 0 if active else stable + 1
        if time.monotonic() > deadline:
            raise RuntimeError("No quiet benchmark window within 30 minutes")
        time.sleep(5)
    print("Timed matrix started", datetime.datetime.now(datetime.timezone.utc).isoformat(), flush=True)
    orders = [[("old", "3473"), ("new", "3473"), ("old", "main"), ("new", "main")],
              [("new", "main"), ("old", "main"), ("new", "3473"), ("old", "3473")],
              [("old", "main"), ("new", "main"), ("old", "3473"), ("new", "3473")]]
    all_values = []
    with open(args.output, "w", buffering=1) as output:
        for round_index in range(args.rounds):
            for client, server in orders[round_index % len(orders)]:
                active = builders()
                if active:
                    raise RuntimeError("A compiler/test started during the benchmark window: " + ", ".join(active))
                scratch = Path("/tmp/cw-fast-load-baseline" if client == "old" else "/tmp/cw-fast-load-final")
                label = "%s-%s-r%d" % (client, server, round_index + 1)
                command = ["/usr/bin/python3", str(Path(__file__).with_name("run.py")), server,
                           "--binary", str(scratch / "release/candy-fast-load"), "--label", label]
                process = subprocess.Popen(command, stdout=subprocess.PIPE, start_new_session=True)
                cell_deadline = time.monotonic() + 400
                while True:
                    try:
                        stdout, _ = process.communicate(timeout=2)
                        break
                    except subprocess.TimeoutExpired:
                        active = builders()
                        if active or time.monotonic() > cell_deadline:
                            os.killpg(process.pid, signal.SIGTERM)
                            process.communicate()
                            detail = "Compiler overlap: " + ", ".join(active) if active else "Cell timeout"
                            raise RuntimeError(detail + "; discard this run")
                if process.returncode:
                    raise subprocess.CalledProcessError(process.returncode, command, stdout)
                active = builders()
                if active:
                    raise RuntimeError("A compiler/test overlapped a benchmark cell; discard this run: " + ", ".join(active))
                for line in stdout.decode().splitlines():
                    value = json.loads(line)
                    value.update(client=client, server=server, round=round_index + 1,
                                 client_commit=(scratch / "client-commit.txt").read_text().strip())
                    output.write(json.dumps(value, sort_keys=True) + "\n")
                    all_values.append(value)
                print("Completed", label, flush=True)
    for server in ["3473", "main"]:
        for phase in ["cold", "history-validation"]:
            hashes = {value["content"]["sha256"] for value in all_values if value["server"] == server and value["phase"] == phase}
            if len(hashes) != 1:
                raise RuntimeError("Restored visible content differs between client versions")
    print("Timed matrix finished", args.output, flush=True)
