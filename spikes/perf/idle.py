#!/usr/bin/env python3
"""Idle cost of the engine, measured next to the owner's running instance without touching it.

Starts `tessera run --dry-run --no-hotkeys --no-menu` on its own socket (it observes and
computes everything but moves nothing), lets it settle, then measures over the given period:
- CPU from the process's accumulated CPU time (`ps -o time`), not from sampled percentages;
- work counters from `tessera debug stats` (timer ticks, window-list copies, SkyLight calls,
  AX queries, renders, journal writes);
- physical footprint and threads.
Checks the plan's §11 idle gates. Activity on the Mac during the period is real work, so run it
while the machine is idle for a clean idle figure."""
import os, re, subprocess, sys, tempfile, time
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
config = sys.argv[1] if len(sys.argv) > 1 else "release"
seconds = int(sys.argv[2]) if len(sys.argv) > 2 else 60
binary = os.path.join(REPO, ".build", config, "tessera")
# Its own state directory: own socket and journal, never the owner's (audit A2).
ENV = {**os.environ, "TESSERA_HOME": tempfile.mkdtemp(prefix="tessera-perf-"), "TESSERA_DEVELOPER": "1", "TESSERA_NO_PROMPT": "1"}
engine = subprocess.Popen([binary, "run", "--dry-run", "--no-hotkeys", "--no-menu"], stderr=subprocess.DEVNULL, env=ENV)

def cpu_seconds():
    t = subprocess.run(["ps", "-o", "time=", "-p", str(engine.pid)], capture_output=True, text=True).stdout.strip()
    parts = [float(x) for x in t.replace("-", ":").split(":")]
    total = 0.0
    for part in parts: total = total * 60 + part
    return total

def stats():
    out = subprocess.run([binary, "debug", "stats"], capture_output=True, text=True, env=ENV).stdout
    pairs = (line.split() for line in out.splitlines() if ":" not in line and line.strip())
    return {p[0]: int(p[1]) for p in pairs if len(p) == 2 and p[1].isdigit()}

time.sleep(6)
c0, s0, t0 = cpu_seconds(), stats(), time.monotonic()
time.sleep(seconds)
c1, s1, t1 = cpu_seconds(), stats(), time.monotonic()
footprint = re.search(r"Footprint: ([\d.]+ \w+)", subprocess.run(["footprint", str(engine.pid)], capture_output=True, text=True).stdout)
threads = len(subprocess.run(["ps", "-M", "-p", str(engine.pid)], capture_output=True, text=True).stdout.splitlines()) - 1
engine.terminate(); engine.wait(timeout=5)

elapsed = t1 - t0
cpu = (c1 - c0) / elapsed * 100
per_minute = {k: round((s1.get(k, 0) - s0.get(k, 0)) * 60 / elapsed, 1) for k in s1}
print(f"{config}, {elapsed:.0f} s: CPU {cpu:.3f} % ({c1 - c0:.2f} s of CPU) | footprint {footprint.group(1) if footprint else '?'} | threads {threads}")
print("work per minute: " + ", ".join(f"{k} {v:g}" for k, v in sorted(per_minute.items()) if v))
ok = cpu < 0.1
print("idle CPU gate (< 0.1 %): " + ("met" if ok else "MISSED"))
sys.exit(0 if ok else 1)
