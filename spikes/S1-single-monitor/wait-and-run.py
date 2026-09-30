#!/usr/bin/env python3
"""Runs the live suite when the owner is away, and leaves their engine running afterwards.

Waits (up to 6 h) for an ordinary desktop Space and a minute without keyboard or mouse input,
stops the owner's engine (a second engine would fight the sandbox), runs the sandbox suite
`--runs N` times, then starts the owner's engine again from the build given with --owner-build
(default: release). Results accumulate in spikes/results/*.jsonl.

usage: wait-and-run.py [--runs N] [--idle SECONDS] [--owner-build release|debug]
"""
import os, signal, subprocess, sys, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from lab import REPO, wait_for_quiet_desktop  # noqa: E402


def argument(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def owner_pids():
    out = subprocess.run(["pgrep", "-f", r"tessera run$"], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def main():
    runs = argument("--runs", "3")
    idle = int(argument("--idle", "60"))
    owner_build = argument("--owner-build", "release")
    if not wait_for_quiet_desktop(idle=idle):
        print("timeout: the owner never left the Mac idle on a desktop")
        return 3
    for pid in owner_pids():
        os.kill(pid, signal.SIGTERM)
    time.sleep(2)
    code = subprocess.run([sys.executable, os.path.join(REPO, "spikes", "S1-single-monitor", "live.py"), "--runs", runs]).returncode
    binary = os.path.join(REPO, ".build", owner_build, "tessera")
    log = open(os.path.expanduser("~/Library/Logs/Tessera/tessera.log"), "a")
    subprocess.Popen([binary, "run"], stdout=log, stderr=log, start_new_session=True)
    time.sleep(2)
    print(f"live suite exit {code}; owner engine restarted from {owner_build}: {owner_pids()}")
    return code


if __name__ == "__main__":
    sys.exit(main())
