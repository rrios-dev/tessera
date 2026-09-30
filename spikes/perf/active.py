#!/usr/bin/env python3
"""Cost of each operation in use: AX round trips, window-server queries and latency.

Sandboxed to DummyWindowApp with emulated workspaces (so hiding and showing are measured too).
For each operation the work counters (`tessera debug stats`) are read before and after, and the
latency is the time until every visible window is drawn at its target."""
import json, os, signal, socket, subprocess, sys, tempfile, time
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BIN = os.path.join(REPO, ".build", os.environ.get("TESSERA_BUILD", "release"))
SOCK, ENGINE_SOCK = "/tmp/tessera-active-dummy.sock", "/tmp/tessera-active-engine.sock"
ENV = {**os.environ, "TESSERA_HOME": tempfile.mkdtemp(prefix="tessera-perf-"), "TESSERA_DEVELOPER": "1", "TESSERA_NO_PROMPT": "1"}

def dummy(sock, payload):
    sock.sendall((json.dumps(payload) + "\n").encode()); data = b""
    while not data.endswith(b"\n"): data += sock.recv(65536)
    return json.loads(data)
def tessera(*w): return subprocess.run([os.path.join(BIN, "tessera"), *w], capture_output=True, text=True, env=ENV)
def stats():
    pairs = (l.split() for l in tessera("debug", "stats").stdout.splitlines() if ":" not in l and l.strip())
    return {p[0]: int(p[1]) for p in pairs if len(p) == 2 and p[1].isdigit()}
def settled():
    s = json.loads(tessera("debug", "state").stdout)
    return not s["mismatches"] and sorted(s["frames"]) == sorted(s["observed"])

def measure(label, action, windows_expected=None):
    time.sleep(0.8)
    before = stats(); start = time.monotonic()
    action()
    latency = None
    while time.monotonic() - start < 3:
        if settled():
            latency = (time.monotonic() - start) * 1000; break
        time.sleep(0.005)
    time.sleep(0.6)
    after = stats()
    d = {k: after[k] - before.get(k, 0) for k in after}
    lat = f"{latency:6.0f} ms" if latency is not None else "   >3 s"
    print(f"{label:<28} {lat}  AX writes {d['axWrites']:3}  AX reads {d['axReads']:3}  scans {d['rescans']:2}  "
          f"window-list {d['windowListCopies']:2}  SkyLight {d['skyLightCalls']:3}  renders {d['renders']:2}", flush=True)

def main():
    for p in (SOCK,):
        if os.path.exists(p): os.unlink(p)
    app = subprocess.Popen([os.path.join(BIN, "DummyWindowApp"), "--socket", SOCK])
    for _ in range(100):
        if os.path.exists(SOCK): break
        time.sleep(0.05)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); sock.connect(SOCK)
    engine = subprocess.Popen([os.path.join(BIN, "tessera"), "run", "--only-pid", str(app.pid), "--no-hotkeys", "--tile-all",
                               "--emulated-workspaces", "--no-menu"], stderr=subprocess.DEVNULL, env=ENV)
    time.sleep(1)
    try:
        ids = []
        def open_window(n):
            spec = {"id": f"w{n}", "frame": {"x": 100, "y": 200, "width": 500, "height": 400}, "fullScreenCapable": False}
            ids.append(str(dummy(sock, {"op": "open", "spec": spec})["windows"][0]["windowNumber"]))
        for n in range(3): measure(f"open window {n + 1}", lambda n=n: open_window(n))
        tessera("focus", "--window-id", ids[2]); time.sleep(0.5)
        measure("move right (split)", lambda: tessera("move", "right"))
        measure("resize width +80", lambda: tessera("resize", "width", "+80"))
        measure("balance-sizes", lambda: tessera("balance-sizes"))
        measure("fullscreen on", lambda: tessera("fullscreen"))
        measure("fullscreen off", lambda: tessera("fullscreen"))
        measure("workspace 2 (hide 3)", lambda: tessera("workspace", "2"))
        measure("workspace 1 (show 3)", lambda: tessera("workspace", "1"))
        measure("close a window", lambda: dummy(sock, {"op": "close", "id": "w1"}))
        before = stats(); time.sleep(20); after = stats()
        idle = {k: after[k] - before.get(k, 0) for k in after if after[k] - before.get(k, 0)}
        print(f"20 s idle afterwards: {idle or 'no work'}")
    finally:
        engine.send_signal(signal.SIGTERM); engine.wait(timeout=5)
        try: dummy(sock, {"op": "quit"})
        except Exception: pass

if __name__ == "__main__":
    sys.exit(main())
