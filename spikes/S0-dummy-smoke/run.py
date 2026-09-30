#!/usr/bin/env python3
"""Smoke test for DummyWindowApp: constraint enforcement under outside frame changes.

Opens five windows, lets whatever window manager is running react, then checks every
window's constraints against both the app's own report and CGWindowList. Finally it
resizes windows through the Accessibility API and reads the result back immediately.
Assertions are about constraints, not positions: another window manager may move them.
"""
import json, os, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(ROOT, "..", ".."))
SOCK = "/tmp/tessera-dummy-smoke.sock"
APP = os.path.join(REPO, ".build", "debug", "DummyWindowApp")

SPECS = [
    {"id": "grid", "frame": {"x": 0, "y": 40, "width": 540, "height": 800},
     "minSize": {"width": 60, "height": 40}, "quantum": {"width": 7, "height": 17}},
    {"id": "bounded", "frame": {"x": 540, "y": 40, "width": 500, "height": 500},
     "minSize": {"width": 400, "height": 300}, "maxSize": {"width": 700, "height": 900}},
    {"id": "aspect", "frame": {"x": 0, "y": 900, "width": 300, "height": 600},
     "aspectRatio": {"width": 9, "height": 19}},
    {"id": "rigid", "frame": {"x": 300, "y": 900, "width": 500, "height": 500}, "rigid": True},
    {"id": "selfish", "frame": {"x": 0, "y": 1600, "width": 600, "height": 400},
     "selfResize": {"afterMilliseconds": 800, "size": {"width": 333, "height": 222}}},
]

def request(sock, payload):
    sock.sendall((json.dumps(payload) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("socket closed")
        data += chunk
    return json.loads(data)

def satisfies(spec, frame):
    w, h = frame["width"], frame["height"]
    problems = []
    if "minSize" in spec and (w < spec["minSize"]["width"] or h < spec["minSize"]["height"]):
        problems.append("below min")
    if "maxSize" in spec and (w > spec["maxSize"]["width"] or h > spec["maxSize"]["height"]):
        problems.append("above max")
    if "quantum" in spec:
        base = spec.get("minSize", {"width": 0, "height": 0})
        if (w - base["width"]) % spec["quantum"]["width"] or (h - base["height"]) % spec["quantum"]["height"]:
            problems.append("off grid")
    if "aspectRatio" in spec:
        r = spec["aspectRatio"]
        expected = (2 * w * r["height"] + r["width"]) // (2 * r["width"])
        if h != expected:
            problems.append(f"aspect {w}x{h}, expected height {expected}")
    return problems

def axprobe(*args):
    out = subprocess.run(["swift", os.path.join(ROOT, "axprobe.swift"), *map(str, args)],
                         capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    return json.loads(out.stdout.strip().splitlines()[-1])

def main():
    results = {"checks": [], "ax": []}
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    app = subprocess.Popen([APP, "--socket", SOCK])
    failures = 0
    try:
        for _ in range(100):
            if os.path.exists(SOCK):
                break
            time.sleep(0.05)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(SOCK)

        opened = {}
        for spec in SPECS:
            response = request(sock, {"op": "open", "spec": spec})
            assert response["ok"], response
            opened[spec["id"]] = response["windows"][0]
        initial_rigid = opened["rigid"]["frame"]

        time.sleep(1.5)  # let the running window manager react and the self-resize fire
        listed = {w["id"]: w for w in request(sock, {"op": "list"})["windows"]}
        numbers = [w["windowNumber"] for w in listed.values()]
        cg = axprobe("bounds", *numbers)["bounds"]

        for spec in SPECS:
            window = listed[spec["id"]]
            reported = window["frame"]
            observed = cg.get(str(window["windowNumber"]))
            problems = satisfies(spec, reported)
            if observed != reported:
                problems.append(f"app reports {reported}, window server has {observed}")
            if spec["id"] == "rigid" and (reported["width"], reported["height"]) != (initial_rigid["width"], initial_rigid["height"]):
                problems.append(f"rigid window resized from {initial_rigid} to {reported}")
            if spec["id"] == "selfish" and (reported["width"], reported["height"]) != (333, 222):
                problems.append(f"self-resize not observed: {reported}")
            failures += bool(problems)
            results["checks"].append({"id": spec["id"], "frame": reported, "windowServer": observed, "problems": problems})

        cases = [("grid", 541, 801), ("bounded", 100, 100), ("bounded", 2000, 2000), ("aspect", 450, 100), ("rigid", 200, 200)]
        for window_id, width, height in cases:
            window = listed[window_id]
            spec = next(s for s in SPECS if s["id"] == window_id)
            probe = axprobe("setsize", app.pid, window["windowNumber"], width, height)
            frame = probe.get("axFrameImmediately")
            problems = [] if frame is None else satisfies(spec, frame)
            if frame is None:
                problems.append(probe.get("error", "no frame"))
            elif frame != probe.get("cgBoundsImmediately"):
                problems.append(f"AX {frame} vs window server {probe.get('cgBoundsImmediately')}")
            if window_id == "rigid" and frame and (frame["width"], frame["height"]) == (200, 200):
                problems.append("rigid window accepted an AX resize")
            failures += bool(problems)
            results["ax"].append({"id": window_id, "requested": [width, height], "result": probe, "problems": problems})

        request(sock, {"op": "quit"})
    finally:
        time.sleep(0.3)
        if app.poll() is None:
            app.terminate()
    os.makedirs(os.path.join(ROOT, "output"), exist_ok=True)
    with open(os.path.join(ROOT, "output", "last-run.json"), "w") as handle:
        json.dump(results, handle, indent=2, sort_keys=True)
    print(json.dumps(results, indent=1, sort_keys=True))
    print(f"\n{failures} failing check(s)")
    return 1 if failures else 0

if __name__ == "__main__":
    sys.exit(main())
