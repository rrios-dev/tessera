"""Shared helpers for Tessera's live tests (audit F5).

Every live test:
- runs its engine in its own state directory (socket, journal, log), never the owner's;
- waits for conditions with a deadline instead of sleeping fixed times;
- tells infrastructure failures (the harness could not set up) from product failures;
- returns the owner to the desktop they started on, and checks it did;
- stops everything it started on exit, Ctrl-C or SIGTERM;
- appends one line per run to spikes/results/<test>.jsonl, so history is never lost.
Nothing here reads window titles.
"""
import datetime, json, os, signal, socket, subprocess, sys, tempfile, time

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
BIN = os.path.join(REPO, ".build", os.environ.get("TESSERA_BUILD", "debug"))
RESULTS = os.path.join(REPO, "spikes", "results")


class Disturbed(Exception):
    """The owner started using the Mac (switched Space): the test stops touching anything."""


def user_idle_seconds():
    out = subprocess.run(["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True).stdout
    for line in out.split("\n"):
        if "HIDIdleTime" in line:
            return int(line.split()[-1]) / 1e9
    return 0.0


def wait_for_quiet_desktop(idle=60, timeout=6 * 3600, poll=10):
    """Blocks until the active Space is an ordinary desktop and nobody has touched the keyboard
    or mouse for `idle` seconds: live tests open windows and synthesize input."""
    deadline = time.time() + timeout
    tool = os.path.join(BIN, "tessera-labtools")
    while time.time() < deadline:
        kind = subprocess.run([tool, "active-space-kind"], capture_output=True, text=True).stdout.strip()
        if kind == "desktop" and user_idle_seconds() >= idle:
            return True
        time.sleep(poll)
    return False


class Lab:
    def __init__(self, name):
        self.name = name
        self.failures = []
        self.checks = 0
        self.log = []
        self.product_started = False
        self.cleanups = []
        self.engine_stop = None
        self.state_dir = tempfile.mkdtemp(prefix=f"tessera-{name}-")
        self.env = dict(os.environ, TESSERA_HOME=self.state_dir, TESSERA_DEVELOPER="1", TESSERA_NO_PROMPT="1")
        parts = self.tool("active-space").split()
        self.start_space = int(parts[0]) if parts else 0
        self.start_kind = parts[1] if len(parts) > 1 else "unknown"
        self.start_desktop = int(parts[2]) if len(parts) > 2 else 0
        for number in (signal.SIGINT, signal.SIGTERM):
            signal.signal(number, self._interrupted)

    def _interrupted(self, number, frame):
        raise KeyboardInterrupt(f"signal {number}")

    # -- tools -----------------------------------------------------------------------------

    def tool(self, *args):
        return subprocess.run([os.path.join(BIN, "tessera-labtools"), *map(str, args)], capture_output=True, text=True).stdout.strip()

    def tessera(self, *words, timeout=20):
        return subprocess.run([os.path.join(BIN, "tessera"), *map(str, words)], capture_output=True, text=True, timeout=timeout, env=self.env)

    def state(self):
        out = self.tessera("debug", "state")
        try:
            return json.loads(out.stdout) if out.returncode == 0 else None
        except json.JSONDecodeError:
            return None

    def invariants(self):
        out = self.tessera("debug", "check")
        return out.returncode == 0, [line for line in out.stdout.split("\n") if line.strip()]

    def ensure_undisturbed(self):
        """Raises `Disturbed` if the owner moved to another Space since the test started."""
        parts = self.tool("active-space").split()
        if not parts or int(parts[0]) != self.start_space:
            raise Disturbed(f"active Space changed from {self.start_space} to {parts[0] if parts else '?'}")

    def drag(self, x1, y1, x2, y2):
        self.ensure_undisturbed()
        self.tool("drag", x1, y1, x2, y2)

    # -- checks ----------------------------------------------------------------------------

    def check(self, ok, message, infra=False):
        self.checks += 1
        kind = "infra" if infra or not self.product_started else "product"
        line = ("ok   " if ok else f"FAIL ({kind}) ") + message
        self.log.append(line)
        print(line, flush=True)
        if not ok:
            self.failures.append({"kind": kind, "message": message})
        return ok

    def wait_for(self, predicate, timeout=5.0, interval=0.05):
        """Polls until `predicate()` is truthy; returns its last value."""
        deadline = time.time() + timeout
        value = None
        while time.time() < deadline:
            try:
                value = predicate()
            except Exception:
                value = None
            if value:
                return value
            time.sleep(interval)
        return value

    # -- processes -------------------------------------------------------------------------

    def start_engine(self, *arguments):
        log = open(os.path.join(self.state_dir, "engine-stderr.log"), "w")
        engine = subprocess.Popen([os.path.join(BIN, "tessera"), "run", *map(str, arguments)], stderr=log, env=self.env)

        def stop():
            if engine.poll() is None:
                engine.send_signal(signal.SIGTERM)
                try:
                    engine.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    engine.kill()
            log.close()
        self.engine_stop = stop
        answered = self.wait_for(lambda: self.tessera("debug", "stats").returncode == 0, timeout=10)
        self.check(bool(answered), "engine started and answers on its own socket", infra=True)
        self.product_started = bool(answered)
        return engine

    def start_dummy(self, label):
        path = os.path.join(self.state_dir, f"dummy-{label}.sock")
        app = subprocess.Popen([os.path.join(BIN, "DummyWindowApp"), "--socket", path])
        self.wait_for(lambda: os.path.exists(path), timeout=5)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(path)

        def stop():
            try:
                Dummy(sock).call({"op": "quit"})
            except Exception:
                pass
            time.sleep(0.2)
            if app.poll() is None:
                app.terminate()
        self.cleanups.append(stop)
        return app, Dummy(sock)

    # -- end -------------------------------------------------------------------------------

    def stop_engine(self):
        """SIGTERM: the engine restores what it hid before exiting."""
        if self.engine_stop:
            self.engine_stop()
            self.engine_stop = None

    def finish(self):
        self.stop_engine()
        for cleanup in reversed(self.cleanups):
            try:
                cleanup()
            except Exception as error:
                print(f"cleanup failed: {error}")
        self.cleanups = []
        # Back to the desktop the owner was on — unless the owner moved on their own: then they
        # are where they want to be and must never be pulled back.
        disturbed = any("owner is using the Mac" in f["message"] for f in self.failures)
        if self.start_desktop and not disturbed:
            now = self.tool("active-space").split()
            if now and int(now[0]) != self.start_space:
                self.tool("go-desktop", self.start_desktop)
                self.wait_for(lambda: int(self.tool("active-space").split()[0]) == self.start_space, timeout=3)
            final = int(self.tool("active-space").split()[0])
            self.check(final == self.start_space, f"the owner is back on the Space they started on ({self.start_space})", infra=True)
        commit = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
        os.makedirs(RESULTS, exist_ok=True)
        with open(os.path.join(RESULTS, f"{self.name}.jsonl"), "a") as handle:
            handle.write(json.dumps({
                "test": self.name, "at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
                "commit": commit, "build": os.environ.get("TESSERA_BUILD", "debug"),
                "checks": self.checks, "failures": self.failures,
            }, sort_keys=True) + "\n")
        product = [f for f in self.failures if f["kind"] == "product"]
        infra = [f for f in self.failures if f["kind"] == "infra"]
        print(f"\n{self.checks} checks, {len(product)} product failure(s), {len(infra)} infra failure(s)")
        return 1 if product else (2 if infra else 0)


class Dummy:
    def __init__(self, sock):
        self.sock = sock

    def call(self, payload):
        self.sock.sendall((json.dumps(payload) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = self.sock.recv(65536)
            if not chunk:
                break
            data += chunk
        return json.loads(data) if data else {}


def rect_area(r):
    return r["width"] * r["height"]


def intersects(a, b):
    return min(a["x"] + a["width"], b["x"] + b["width"]) > max(a["x"], b["x"]) and \
        min(a["y"] + a["height"], b["y"] + b["height"]) > max(a["y"], b["y"])


def inside(r, area):
    return r["x"] >= area["x"] and r["y"] >= area["y"] and r["x"] + r["width"] <= area["x"] + area["width"] \
        and r["y"] + r["height"] <= area["y"] + area["height"]


def runs_from_arguments(default=1):
    """`--runs N` repeats a test N times (plan §12: a challenge passes 20 accumulated runs)."""
    if "--runs" in sys.argv:
        return int(sys.argv[sys.argv.index("--runs") + 1])
    return default
