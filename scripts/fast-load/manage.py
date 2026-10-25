#!/usr/bin/env python3
"""Start/stop only the two isolated fast-load servers and their proxies."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import time
import urllib.request

from run import BASE, clean_environment


def stop(name, kind):
    pidfile = BASE / name / (kind + ".pid")
    if not pidfile.exists():
        return
    pid = int(pidfile.read_text())
    command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
    expected = str(BASE / name / "t3home") if kind == "server" else str(BASE / name / "proxy.jsonl")
    if not command:
        pidfile.unlink()
        return
    if expected not in command:
        raise RuntimeError("PID no longer belongs to this sandbox; refusing to signal it")
    os.kill(pid, signal.SIGTERM)
    for _ in range(100):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pidfile.unlink()
            print("stopped", name, kind, pid)
            return
        time.sleep(0.1)
    raise RuntimeError("Sandbox PID did not exit after SIGTERM: %d" % pid)


def start(name, port):
    home = BASE / name / "t3home"
    home.mkdir(parents=True, exist_ok=True)
    for kind in ["server", "proxy"]:
        pidfile = BASE / name / (kind + ".pid")
        if pidfile.exists():
            raise RuntimeError("Stop the recorded sandbox processes first: " + str(pidfile))
    command = ([str(Path.home() / "CandyWrapper-research/runtimes/t3-0.1.2-nightly.20261021.3473-darwin-arm64/t3")]
               if name == "3473" else ["/opt/homebrew/bin/node", str(BASE / "source-main/apps/server/src/bin.ts")])
    server = subprocess.Popen(command + ["serve", "--base-dir", str(home), "--port", str(port),
        "--host", "127.0.0.1", "--no-browser"], env=clean_environment(), cwd=BASE,
        stdout=open(BASE / name / "server.log", "a"), stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL, start_new_session=True)
    (BASE / name / "server.pid").write_text(str(server.pid))
    proxy = subprocess.Popen(["/usr/bin/python3", str(Path(__file__).with_name("proxy.py")),
        "--port", str(port + 100), "--target", str(port), "--log", str(BASE / name / "proxy.jsonl")],
        env=clean_environment(), stdout=open(BASE / name / "proxy.stdout", "a"), stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL, start_new_session=True)
    (BASE / name / "proxy.pid").write_text(str(proxy.pid))
    print(name, "server PID", server.pid, "proxy PID", proxy.pid, flush=True)
    for _ in range(90):
        if server.poll() is not None:
            raise RuntimeError("Server exited; see its sandbox log")
        try:
            with urllib.request.urlopen("http://127.0.0.1:%d/.well-known/t3/environment" % port, timeout=1):
                return
        except OSError:
            time.sleep(0.5)
    raise RuntimeError("Server readiness timed out")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["start", "stop"])
    args = parser.parse_args()
    for name, port in [("3473", 47441), ("main", 47442)]:
        if args.action == "start":
            start(name, port)
        else:
            stop(name, "proxy")
            stop(name, "server")
