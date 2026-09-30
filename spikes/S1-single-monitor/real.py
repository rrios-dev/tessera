#!/usr/bin/env python3
"""Live check of Tessera on the owner's real apps, with AeroSpace paused.

Order is fixed and the finally-block always runs: pause AeroSpace, run Tessera on every
app of the desktop Space, measure, stop Tessera (SIGTERM restores hidden windows), check no
window is left parked, and turn AeroSpace back on. Nothing here reads window titles.
"""
import json, os, shutil, signal, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(ROOT, "..", ".."))
BIN = os.path.join(REPO, ".build", os.environ.get("TESSERA_BUILD", "debug"))
TOOLS = os.path.join(BIN, "tessera-labtools")
# Its own state directory (socket, journal): the owner's engine must be stopped first, but its
# files are never touched (audit A2).
ENV = {**os.environ, "TESSERA_HOME": tempfile.mkdtemp(prefix="tessera-real-"), "TESSERA_NO_PROMPT": "1", "TESSERA_DEVELOPER": "1"}
OUT = os.path.join(ROOT, "output")
failures, log, snapshots = [], [], {}

def check(condition, message):
    log.append(("ok  " if condition else "FAIL") + " " + message)
    print(log[-1], flush=True)
    if not condition:
        failures.append(message)

def tessera(*words):
    return subprocess.run([os.path.join(BIN, "tessera"), *words], capture_output=True, text=True, timeout=20, env=ENV)

def state():
    out = tessera("debug", "state")
    return json.loads(out.stdout) if out.returncode == 0 else None

def intersects(a, b):
    return min(a["x"] + a["width"], b["x"] + b["width"]) > max(a["x"], b["x"]) and \
           min(a["y"] + a["height"], b["y"] + b["height"]) > max(a["y"], b["y"])

def verify(label, partition=True, wait=2.5):
    time.sleep(wait)
    s = state()
    snapshots[label] = s
    if s is None:
        check(False, f"{label}: engine answers")
        return None
    area = s["area"]
    frames, observed = s["frames"], s["observed"]
    check(sorted(frames) == sorted(observed), f"{label}: all {len(frames)} target windows drawn")
    check(not s["mismatches"], f"{label}: drawn = target (mismatches {s['mismatches']}, facts {s['facts']})")
    if s.get("reflowed"):
        check(True, f"{label}: {s['reflowed']} container(s) reflowed to fit the portrait monitor")
    if s.get("overflowed"):
        check(True, f"{label}: {s['overflowed']} container(s) overflowed into an accordion (overlap by design)")
        partition = False
    if partition and frames:
        rects = list(observed.values())
        overlaps = sum(1 for i, a in enumerate(rects) for b in rects[i + 1:] if intersects(a, b))
        covered = sum(r["width"] * r["height"] for r in rects)
        total = area["width"] * area["height"]
        check(overlaps == 0, f"{label}: no overlaps ({overlaps})")
        check(covered == total, f"{label}: no holes (covered {covered} of {total}, {total - covered} missing)")
    return s

def parked_windows(area):
    """Layer-0 windows whose top-left sits in the hiding corner (title-free)."""
    out = subprocess.run([TOOLS, "parked", str(area["x"] + area["width"] - 2), str(area["y"] + area["height"] - 2)], capture_output=True, text=True)
    return [line for line in out.stdout.split("\n") if line]

def main():
    kind = subprocess.run([TOOLS, "active-space-kind"], capture_output=True, text=True).stdout.strip()
    if kind != "desktop":
        print(f"active Space is {kind}; the real-app test needs a desktop Space")
        return 2
    visible = int(subprocess.run([TOOLS, "visible-windows"], capture_output=True, text=True).stdout.strip() or 0)
    if visible < 2:
        print(f"only {visible} window(s) visible on this desktop; the real-app test needs at least two")
        return 2
    engine = None
    area = None
    try:
        if shutil.which("aerospace"): subprocess.run(["aerospace", "enable", "off"], check=False)
        check(True, "AeroSpace paused")
        time.sleep(1.5)
        engine_log = open(os.path.join(OUT, "real-engine.log"), "w")
        engine = subprocess.Popen([os.path.join(BIN, "tessera"), "run", "--no-menu", "--emulated-workspaces"], stderr=engine_log, env=ENV)
        s = verify("start: every app of the desktop tiled", wait=5)
        if s is None:
            return 1
        area = s["area"]
        tiled = sum(len(w["tiled"]) for sp in s["spaces"] if sp["id"] == s["activeSpace"] for w in sp["workspaces"])
        check(tiled >= 2, f"{tiled} real windows tiled on the active desktop")
        if tiled < 2:
            print("the active desktop has fewer than two manageable windows; nothing meaningful to test")
            return 1

        tessera("balance-sizes"); verify("balance-sizes")
        tessera("layout", "accordion"); verify("accordion", partition=False)
        tessera("layout", "tiles"); verify("back to tiles")
        tessera("layout", "monocle")
        m = verify("monocle", partition=False)
        if m:
            full = [k for k, r in m["observed"].items() if r == m["area"]]
            check(1 <= len(full) <= 2, f"monocle: {len(full)} window(s) at full size, {len(m['hidden'])} hidden")
        tessera("layout", "tiles"); verify("tiles again")
        tessera("fullscreen")
        f = verify("Tessera full screen", partition=False)
        if f and f.get("focused") is not None:
            check(f["observed"].get(str(f.get("focused"))) == f["area"], "focused window covers the desktop")
        tessera("fullscreen"); verify("full screen off")
        tessera("workspace", "2")
        w = verify("empty Tessera workspace 2", partition=False)
        if w:
            check(not w["frames"] and len(w["hidden"]) == tiled, f"everything hidden ({len(w['hidden'])} of {tiled})")
        tessera("workspace", "back-and-forth"); verify("back to workspace 1")
        tessera("move", "right"); verify("move right")
        tessera("resize", "width", "+80"); verify("resize width +80")
        tessera("balance-sizes"); verify("final balance")
    finally:
        if engine is not None:
            engine.send_signal(signal.SIGTERM)
            try:
                engine.wait(timeout=8)
            except subprocess.TimeoutExpired:
                engine.kill()
        time.sleep(1)
        if area:
            parked = parked_windows(area)
            check(not parked, f"after Tessera quit no window is parked in the corner ({len(parked)})")
        if shutil.which("aerospace"): subprocess.run(["aerospace", "enable", "on"], check=False)
        check(True, "AeroSpace re-enabled")
    with open(os.path.join(OUT, "real-run.json"), "w") as handle:
        json.dump({"log": log, "snapshots": snapshots}, handle, indent=1, sort_keys=True)
    print(f"\n{len(failures)} failure(s)")
    return 1 if failures else 0

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    sys.exit(main())
