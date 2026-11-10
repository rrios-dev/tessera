"""Audit of Tessera's MCP integration against the owner's running engine (ADR 0005).

Unlike the other live tests this one drives the OWNER's installed engine, because what it
audits is the path an agent takes: run it only when the owner asks, with the Mac idle. It
opens three TextEdit documents named SECRETO-n.txt on the first desktop, acts only on them
(except revert-layout, which every window undergoes), and restores the owner's windows, the
configuration and their Space. First run 2026-10-14: 70/70 after the fixes it found.

    python3 spikes/mcp-audit/audit.py

Every tool is called through `tessera mcp` over stdio, as Claude Code does. Every effect is
checked against an independent oracle: the engine's own state (`tessera debug state`) and
the frames the window server draws. Test windows are DummyWindowApp windows; the owner's
windows are only touched by test 18 (revert-layout) and are checked afterwards. Whatever
happens, the configuration, the test windows and the owner's Space are restored.
"""
import json, os, select, socket, subprocess, sys, tempfile, time

HOME = os.path.expanduser("~")
INSTALLED = os.path.join(HOME, ".local/bin/tessera")
REPO = "/Volumes/Desarrollo/projects/tessera"
UNSIGNED = os.path.join(REPO, ".build/debug/tessera")
LABTOOLS = os.path.join(REPO, ".build/debug/tessera-labtools")
DUMMY = os.path.join(REPO, ".build/debug/DummyWindowApp")
CONFIG = os.path.join(HOME, ".config/tessera/tessera.local.toml")
LOG = os.path.join(HOME, "Library/Application Support/Tessera/agent-access.log")
OUT = os.path.join(REPO, "spikes", "results")
SECRET = "SECRETO-123"

results = []


def check(test, ok, detail):
    results.append({"test": test, "ok": bool(ok), "detail": detail})
    print(("ok    " if ok else "FAIL  ") + f"[{test}] {detail}", flush=True)
    return ok


def wait_for(predicate, timeout=5.0, interval=0.1):
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


class MCP:
    """One stdio session with an MCP server, as a client would hold it."""

    def __init__(self, binary, env=None, client="audit"):
        self.process = subprocess.Popen([binary, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, env=env, text=True, bufsize=1)
        self.next_id = 0
        self.info = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                "clientInfo": {"name": client, "version": "1"}})
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")

    def request(self, method, params=None, timeout=20):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            ready, _, _ = select.select([self.process.stdout], [], [], 0.5)
            if ready:
                line = self.process.stdout.readline()
                if not line:
                    raise RuntimeError("server closed")
                reply = json.loads(line)
                if reply.get("id") == self.next_id:
                    return reply
        raise TimeoutError(method)

    def call(self, name, **arguments):
        reply = self.request("tools/call", {"name": name, "arguments": arguments})
        result = reply.get("result", {})
        text = "".join(c.get("text", "") for c in result.get("content", []))
        return result.get("isError", True), text, result.get("structuredContent")

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=5)
        except Exception:
            self.process.kill()


def state():
    out = subprocess.run([INSTALLED, "debug", "state"], capture_output=True, text=True, timeout=10)
    return json.loads(out.stdout) if out.returncode == 0 else None


def lab(*words):
    return subprocess.run([LABTOOLS, *map(str, words)], capture_output=True, text=True).stdout.strip()


def active_space():
    parts = lab("active-space").split()
    return (int(parts[0]), parts[1], int(parts[2]) if len(parts) > 2 else 0) if parts else (0, "?", 0)


def workspace(s, space_id):
    space = next(sp for sp in s["spaces"] if sp["id"] == space_id)
    return next(w for w in space["workspaces"] if w["name"] == space["activeWorkspace"])


def frame(s, wid, kind="frames"):
    f = s.get(kind, {}).get(str(wid))
    return (f["x"], f["y"], f["width"], f["height"]) if f else None


def center(f):
    return (f[0] + f[2] / 2, f[1] + f[3] / 2)


def idle_seconds():
    out = subprocess.run(["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True).stdout
    for line in out.split("\n"):
        if "HIDIdleTime" in line:
            return int(line.split()[-1]) / 1e9
    return 0.0


class TextEditWindows:
    """Real app windows Tessera manages: TextEdit documents named SECRETO-n.txt, so a title
    leak would show. TextEdit was not running; it is quit without saving at the end."""

    def __init__(self, count):
        self.directory = tempfile.mkdtemp(prefix="tessera-mcp-audit-")
        self.files = []
        for index in range(count):
            path = os.path.join(self.directory, f"{SECRET}-{index}.txt")
            open(path, "w").write(f"Tessera MCP audit window {index}\n")
            self.files.append(path)

    def open(self):
        subprocess.run(["open", "-a", "TextEdit", *self.files])

    def quit(self):
        subprocess.run(["osascript", "-e", 'tell application "TextEdit" to quit saving no'], capture_output=True)
        time.sleep(1.0)


def main():
    original_config = open(CONFIG).read()
    start = active_space()
    print(f"start Space {start}", flush=True)
    session = MCP(INSTALLED)
    dummies = None
    desktop_space = None
    owner_windows, owner_frames = [], {}
    fullscreen_app = None
    try:
        # ---------------------------------------------------------------- A1 connection
        info = session.info.get("result", {})
        check("A1", info.get("serverInfo", {}).get("name") == "tessera" and info.get("protocolVersion") == "2025-06-18",
              f"initialize: {info.get('serverInfo')} protocol {info.get('protocolVersion')}")
        tools = session.request("tools/list")["result"]["tools"]
        names = [t["name"] for t in tools]
        expected = ["get_layout", "focus_window", "focus", "move_window", "move_to_workspace", "switch_workspace",
                    "set_layout", "resize", "toggle_fullscreen", "balance_sizes", "engine"]
        check("A1", names == expected, f"{len(names)} tools: {', '.join(names)}")
        read_only = [t["name"] for t in tools if t["annotations"]["readOnlyHint"]]
        check("A1", read_only == ["get_layout"], f"read-only: {read_only}")
        check("A1", all(t["inputSchema"]["type"] == "object" for t in tools), "every tool has an object schema")

        error, text, _ = session.call("get_layout")
        fullscreen_line = text.split("\n")[0] if text.startswith("Focused") else ""
        fullscreen_app = fullscreen_line.split("(")[-1].rstrip(")") if fullscreen_line else None
        print(f"focused before: {fullscreen_line}", flush=True)

        # ---------------------------------------------------------------- A2 the switch
        try:
            open(CONFIG, "w").write(original_config.replace("enabled = true", "enabled = false"))
            error, text, _ = session.call("get_layout")
            check("A2", error and "agent access is off" in text, f"off → refused: {text[:90]}")
            error2, text2, _ = session.call("balance_sizes")
            check("A2", error2 and "agent access is off" in text2, "off → commands refused too")
        finally:
            open(CONFIG, "w").write(original_config)
        error, text, _ = session.call("get_layout")
        check("A2", not error, "on again → works without restarting the server")

        # ---------------------------------------------------------------- A4 engine missing
        empty = tempfile.mkdtemp(prefix="tessera-no-engine-")
        lonely = MCP(INSTALLED, env=dict(os.environ, TESSERA_HOME=empty))
        error, text, _ = lonely.call("get_layout")
        check("A4", error and "Tessera is not running" in text, f"no engine → {text}")
        lonely.close()

        # ---------------------------------------------------------------- A5 bad arguments
        for name, arguments, needle in [
            ("focus", {"direction": "sideways"}, "must be one of"),
            ("resize", {"dimension": "height", "points": 0}, "non-zero"),
            ("resize", {"dimension": "depth", "points": 10}, "must be one of"),
            ("engine", {"action": "uninstall"}, "must be one of"),
            ("set_layout", {"layout": "spiral"}, "must be one of"),
            ("focus_window", {}, "required"),
            ("focus_window", {"window_id": "abc"}, "integer"),
        ]:
            error, text, _ = session.call(name, **arguments)
            check("A5", error and needle in text, f"{name} {arguments} → {text}")
        error, text, _ = session.call("focus_window", window_id=999999)
        check("A5", error and "No window 999999" in text, f"window that does not exist → {text}")

        # ---------------------------------------------------------------- A6 signature
        if os.path.exists(UNSIGNED):
            unsigned = MCP(UNSIGNED, client="unsigned")
            error, text, _ = unsigned.call("get_layout")
            check("A6", not error, "unsigned build: reading the layout is allowed")
            error, text, _ = unsigned.call("balance_sizes")
            check("A6", error and "signed by Tessera's developer" in text, f"unsigned build: command → {text}")
            unsigned.close()
        else:
            check("A6", False, "no unsigned debug build to test with")

        # ---------------------------------------------------------------- go to the desktop
        wait_for(lambda: idle_seconds() >= 10, timeout=90, interval=1)
        if idle_seconds() < 10:
            check("setup", False, f"the Mac is in use (idle {idle_seconds():.0f}s): stopping before moving anything")
            return
        lab("go-desktop", 1)
        desktop = wait_for(lambda: active_space()[1] == "desktop" and active_space(), timeout=5)
        if not desktop:
            check("setup", False, "could not reach an ordinary desktop")
            return
        desktop_space = desktop[0]
        print(f"on desktop Space {desktop_space}", flush=True)
        baseline = wait_for(state, timeout=5)
        owner_windows = workspace(baseline, desktop_space)["tiled"] + workspace(baseline, desktop_space)["floating"]
        owner_frames = {w: frame(baseline, w, "observed") for w in owner_windows}
        print(f"owner's windows {owner_windows} at {owner_frames}", flush=True)

        # ---------------------------------------------------------------- test windows
        dummies = TextEditWindows(3)
        dummies.open()

        def new_windows():
            ws = workspace(state(), desktop_space)
            found = [w for w in ws["tiled"] if w not in owner_windows]
            return found if len(found) == 3 else None
        ids = wait_for(new_windows, timeout=10)
        if not check("setup", bool(ids), f"Tessera tiles the three TextEdit windows: {ids}"):
            return
        time.sleep(0.8)

        # ---------------------------------------------------------------- A7 / B8 reading
        error, text, structured = session.call("get_layout")
        check("A7", SECRET not in text and SECRET not in json.dumps(structured), "no window title in the output (text and JSON)")
        s = state()
        desktop_json = next(d for d in structured["desktops"] if d["id"] == str(desktop_space))
        active_ws = next(w for w in desktop_json["workspaces"] if w["active"])
        mcp_windows = {w["id"]: w for w in active_ws["windows"]}
        oracle_ws = workspace(s, desktop_space)
        check("B8", set(mcp_windows) == set(oracle_ws["tiled"] + oracle_ws["floating"]),
              f"same windows as the engine: {sorted(mcp_windows)}")
        check("B8", structured["focused"] == s["focused"], f"same focused window: {structured['focused']}")
        frames_ok = all((w.get("frame") and (w["frame"]["x"], w["frame"]["y"], w["frame"]["width"], w["frame"]["height"]) == frame(s, i))
                        for i, w in mcp_windows.items() if frame(s, i))
        check("B8", frames_ok, "every frame equals the engine's target")
        check("B8", all(mcp_windows[i]["app"] == "TextEdit" and mcp_windows[i]["bundleId"] == "com.apple.TextEdit" for i in ids), "test windows named by their app: TextEdit (com.apple.TextEdit)")
        brave = [w for w in mcp_windows.values() if w["id"] in owner_windows]
        check("B8", all(w["bundleId"] == "com.brave.Browser" for w in brave), f"owner's windows: {[(w['app'], w['bundleId']) for w in brave]}")
        kinds = {d["id"]: d["kind"] for d in structured["desktops"]}
        real_kinds = {l.split()[0]: l.split()[1] for l in lab("spaces").split("\n") if l.strip()}
        check("B8", kinds == real_kinds, f"desktops and kinds as macOS reports them: {kinds}")
        mismatched = [m for m in s.get("mismatches", []) if m in ids]
        check("B8", not mismatched, "the window server draws the test windows where Tessera put them")

        # ---------------------------------------------------------------- C9 focus
        for wid in ids:
            error, text, _ = session.call("focus_window", window_id=wid)
            ok = wait_for(lambda: state()["focused"] == wid, timeout=3)
            check("C9", not error and ok, f"focus_window {wid} → focused {state()['focused']}")
            time.sleep(0.3)
        for direction in ["up", "down", "left", "right"]:
            before = state()
            source = before["focused"]
            source_center = center(frame(before, source))
            error, text, _ = session.call("focus", direction=direction)
            time.sleep(0.6)
            after = state()
            target = after["focused"]
            if target == source:
                check("C9", not error, f"focus {direction}: no neighbour that way, focus stays ({text})")
            else:
                c = center(frame(after, target))
                dx, dy = c[0] - source_center[0], c[1] - source_center[1]
                right_way = {"up": dy < 0, "down": dy > 0, "left": dx < 0, "right": dx > 0}[direction]
                check("C9", not error and right_way, f"focus {direction}: {source} → {target} (moved {dx:+.0f},{dy:+.0f})")
            time.sleep(0.3)

        # ---------------------------------------------------------------- C10 move
        moved = ids[1]
        for direction in ["up", "down"]:
            before = workspace(state(), desktop_space)["tiled"]
            error, text, _ = session.call("move_window", direction=direction, window_id=moved)
            time.sleep(0.8)
            after = workspace(state(), desktop_space)["tiled"]
            shift = after.index(moved) - before.index(moved) if moved in after and moved in before else None
            check("C10", not error and shift is not None and shift != 0 or before.index(moved) in (0, len(before) - 1),
                  f"move_window {direction} {moved}: order {before} → {after}")
            time.sleep(0.4)
        s = state()
        check("C10", not [m for m in s.get("mismatches", []) if m in ids], "drawn frames match after moving")

        # ---------------------------------------------------------------- C11 layouts
        session.call("focus_window", window_id=ids[0])
        time.sleep(0.4)
        for mode in ["accordion", "monocle", "tiles"]:
            error, text, _ = session.call("set_layout", layout=mode)
            ok = wait_for(lambda: workspace(state(), desktop_space)["layout"] == mode, timeout=3)
            check("C11", not error and ok, f"set_layout {mode} → workspace layout {workspace(state(), desktop_space)['layout']}")
            time.sleep(0.5)
        before = {i: frame(state(), i) for i in ids}
        error, text, _ = session.call("set_layout", layout="toggle-orientation")
        time.sleep(0.8)
        after_state = state()
        after = {i: frame(after_state, i) for i in ids}
        check("C11", not error and (before != after or after_state["reflowed"] > 0),
              "toggle-orientation: rearranged" if before != after else
              f"toggle-orientation: side by side does not fit on {after_state['area']['width']} points, so Tessera keeps the column (reflowed {after_state['reflowed']})")
        session.call("set_layout", layout="toggle-orientation")
        time.sleep(0.8)
        check("C11", {i: frame(state(), i) for i in ids} == before, "toggling again restores it")
        error, text, _ = session.call("set_layout", layout="floating")
        ok = wait_for(lambda: ids[0] in workspace(state(), desktop_space)["floating"], timeout=3)
        check("C11", not error and ok, "floating: the window leaves the tiling")
        session.call("set_layout", layout="floating")
        ok = wait_for(lambda: ids[0] in workspace(state(), desktop_space)["tiled"], timeout=3)
        check("C11", bool(ok), "floating again: the window is tiled again")
        time.sleep(0.6)

        # ---------------------------------------------------------------- C12 resize
        target = ids[1]
        for dimension, index in [("height", 3), ("width", 2)]:
            for points in [80, -80]:
                before = frame(state(), target)
                error, text, _ = session.call("resize", dimension=dimension, points=points, window_id=target)
                time.sleep(0.8)
                after = frame(state(), target)
                delta = after[index] - before[index]
                if delta == 0:
                    check("C12", not error, f"resize {dimension} {points:+}: no room on that axis here, size kept ({before[index]})")
                else:
                    check("C12", not error and (delta > 0) == (points > 0) and abs(abs(delta) - abs(points)) <= 20,
                          f"resize {dimension} {points:+}: {before[index]} → {after[index]} ({delta:+})")
                time.sleep(0.3)

        # ---------------------------------------------------------------- C13 full size
        session.call("focus_window", window_id=ids[2])
        time.sleep(0.4)
        before = frame(state(), ids[2])
        area = state()["area"]
        error, text, _ = session.call("toggle_fullscreen")
        time.sleep(0.8)
        full = frame(state(), ids[2])
        check("C13", not error and full[2] >= area["width"] - 40 and full[3] >= area["height"] - 40,
              f"toggle_fullscreen: {before} → {full} (usable {area['width']}×{area['height']})")
        session.call("toggle_fullscreen")
        time.sleep(0.8)
        check("C13", frame(state(), ids[2]) == before, f"toggle again: back to {frame(state(), ids[2])}")

        # ---------------------------------------------------------------- C14 balance
        session.call("resize", dimension="height", points=120, window_id=ids[0])
        time.sleep(0.6)
        error, text, _ = session.call("balance_sizes")
        time.sleep(0.8)
        s = state()
        tiled_now = workspace(s, desktop_space)["tiled"]
        heights = [frame(s, w)[3] for w in tiled_now]
        widths = [frame(s, w)[2] for w in tiled_now]
        spread = min(max(heights) - min(heights), max(widths) - min(widths))
        check("C14", not error and spread <= 4, f"balance_sizes: heights {heights}, widths {widths}")

        # ---------------------------------------------------------------- C15 engine
        error, text, _ = session.call("engine", action="pause")
        check("C15", not error, f"pause → {text}")
        before = frame(state(), ids[1])
        error, text, _ = session.call("resize", dimension="height", points=60, window_id=ids[1])
        time.sleep(0.6)
        check("C15", error and "paused" in text.lower() and frame(state(), ids[1]) == before,
              f"while paused a command is refused and nothing moves: {text}")
        error, text, _ = session.call("engine", action="resume")
        check("C15", not error, f"resume → {text}")
        time.sleep(0.5)
        error, text, _ = session.call("engine", action="retile")
        time.sleep(1.0)
        s = state()
        check("C15", not error and not [m for m in s.get("mismatches", []) if m in ids], "retile: everything drawn where Tessera says")

        # ---------------------------------------------------------------- C16 bursts
        time.sleep(2.5)
        outcomes = [session.call("balance_sizes") for _ in range(30)]
        limited = [t for e, t, _ in outcomes if e]
        check("C16", limited and all("rate limited" in t for t in limited),
              f"30 commands at once: {30 - len(limited)} run, {len(limited)} refused with “{limited[0] if limited else ''}”")
        time.sleep(2.5)
        outcomes = [session.call("focus_window", window_id=ids[i % 3]) for i in range(12)]
        limited = [t for e, t, _ in outcomes if e]
        check("C16", limited and all("rate limited" in t for t in limited), f"12 focus changes at once: {12 - len(limited)} run, {len(limited)} refused")
        time.sleep(2.5)

        # ---------------------------------------------------------------- D17 workspaces
        error, text, _ = session.call("switch_workspace", workspace="2")
        time.sleep(1.5)
        now = active_space()
        check("D17", error and "there is no desktop 2" in text and now[0] == desktop_space,
              f"switch_workspace 2 with one desktop → {text}; still on Space {now[0]}")
        error, text, _ = session.call("switch_workspace", workspace="1")
        time.sleep(1.0)
        check("D17", not error and active_space()[0] == desktop_space, f"switch_workspace 1 → {text}")
        if now[0] != desktop_space:
            lab("go-desktop", 1)
            wait_for(lambda: active_space()[0] == desktop_space, timeout=5)
        check("D17", active_space()[0] == desktop_space, "back on the test desktop")
        error, text, _ = session.call("move_to_workspace", workspace="2", window_id=ids[2])
        time.sleep(1.5)
        s = state()
        here = ids[2] in workspace(s, desktop_space)["tiled"] + workspace(s, desktop_space)["floating"]
        check("D17", error and "does not let Tessera move windows between desktops" in text and here,
              f"move_to_workspace 2 → {text}")
        if active_space()[0] != desktop_space:
            lab("go-desktop", 1)
            wait_for(lambda: active_space()[0] == desktop_space, timeout=5)

        # ---------------------------------------------------------------- D18 revert
        error, text, _ = session.call("engine", action="revert-layout")
        time.sleep(1.5)
        reverted = state()
        stats = subprocess.run([INSTALLED, "debug", "stats"], capture_output=True, text=True).stdout
        status = stats.split("status:")[-1].split()[0] if "status:" in stats else "?"
        moved_back = {w: frame(reverted, w, "observed") for w in owner_windows}
        check("D18", not error and status == "paused", f"revert-layout → {text}; Tessera pauses itself ({status}); owner's windows now {moved_back}")
        error, text, _ = session.call("engine", action="retile")
        time.sleep(1.5)
        check("D18", not error and "Tessera is now active" in text, f"retile while paused resumes and relays out, and says so: {text}")
        s = state()
        check("D18", all(w in workspace(s, desktop_space)["tiled"] for w in owner_windows),
              f"everything tiled again: {workspace(s, desktop_space)['tiled']}")
    finally:
        # ---------------------------------------------------------------- E19 cleanup
        if open(CONFIG).read() != original_config:
            open(CONFIG, "w").write(original_config)
        if dummies:
            dummies.quit()
            wait_for(lambda: not any(i in json.dumps(state()["spaces"]) for i in []), timeout=1)
            time.sleep(1.5)
            session.call("engine", action="resume")
            time.sleep(1.5)
            s = state()
            if s and desktop_space:
                ws = workspace(s, desktop_space)
                left = ws["tiled"] + ws["floating"]
                check("E19", set(left) == set(owner_windows), f"only the owner's windows remain: {left}")
                first = owner_windows[0]
                if len(owner_windows) == 2 and frame(s, first, "observed") and owner_frames.get(first):
                    delta = owner_frames[first][3] - frame(s, first, "observed")[3]
                    if delta:
                        session.call("resize", dimension="height", points=delta, window_id=first)
                        time.sleep(1.0)
                    s = state()
                restored = {w: frame(s, w, "observed") for w in owner_windows}
                close = all(restored[w] and owner_frames[w] and all(abs(a - b) <= 2 for a, b in zip(restored[w], owner_frames[w])) for w in owner_windows)
                check("E19", close, f"owner's windows back where they were: {restored} (before {owner_frames})")
        session.close()
        if fullscreen_app and active_space()[0] != start[0]:
            subprocess.run(["osascript", "-e", f'tell application "{fullscreen_app}" to activate'], capture_output=True)
            wait_for(lambda: active_space()[0] == start[0], timeout=5)
        check("E19", active_space()[0] == start[0], f"the owner is back on the Space they started on ({start[0]})")
        lines = open(LOG).read().strip().split("\n")[-200:]
        mode = oct(os.stat(LOG).st_mode & 0o777)
        audit_lines = [json.loads(l) for l in lines if '"audit"' in l]
        check("A3", mode == "0o600", f"access log mode {mode}")
        check("A3", audit_lines and all(set(e) == {"client", "date", "succeeded", "tool"} for e in audit_lines),
              f"{len(audit_lines)} entries from this audit, fields: client, date, succeeded, tool")
        check("A3", SECRET not in "\n".join(lines) and "sideways" not in "\n".join(lines), "no arguments or titles in the log")
        import datetime
        commit = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
        with open(os.path.join(OUT, "mcp-audit.jsonl"), "a") as handle:
            handle.write(json.dumps({"test": "mcp-audit", "at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
                                     "commit": commit, "checks": len(results),
                                     "failures": [r for r in results if not r["ok"]]}, sort_keys=True) + "\n")
        failed = [r for r in results if not r["ok"]]
        print(f"\n{len(results)} checks, {len(failed)} failed")


if __name__ == "__main__":
    main()
