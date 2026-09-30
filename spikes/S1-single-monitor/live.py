#!/usr/bin/env python3
"""Live single-monitor check of the engine, sandboxed to two DummyWindowApp processes.

Tessera runs with --only-pid in its own state directory, so it manages nothing but the test
windows and never touches the owner's engine, socket or journal. Every step waits for the
window server to agree with Tessera's targets (`tessera debug state`), then checks that tiled
windows partition the area and that every invariant holds (`tessera debug check`).

usage: live.py [--runs N]
"""
import json, os, sys, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from lab import Lab, Disturbed, rect_area, intersects, inside, runs_from_arguments  # noqa: E402


def run_once():
    lab = Lab("S1-live")
    if lab.start_kind != "desktop":
        print(f"the active Space is {lab.start_kind}: the live test needs a desktop Space")
        return 2
    try:
        app1, one = lab.start_dummy("one")
        app2, two = lab.start_dummy("two")
        lab.start_engine("--only-pid", app1.pid, "--only-pid", app2.pid, "--no-hotkeys", "--tile-all",
                         "--emulated-workspaces", "--no-menu")

        def open_window(dummy, wid, **extra):
            # No native full-screen button: another window manager would take these as dialogs.
            spec = {"id": wid, "frame": {"x": 100, "y": 100, "width": 400, "height": 300}, "fullScreenCapable": False, **extra}
            return dummy.call({"op": "open", "spec": spec})["windows"][0]["windowNumber"]

        def settled(expect_windows=None, allow_mismatch=False):
            def ready():
                s = lab.state()
                if not s or (expect_windows is not None and len(s["frames"]) != expect_windows):
                    return None
                if sorted(s["frames"]) != sorted(s["observed"]):
                    return None
                if allow_mismatch:
                    # Slack allowed, but every window placed: at its tile's corner, within it.
                    placed = all(abs(s["observed"][k]["x"] - t["x"]) <= 4 and abs(s["observed"][k]["y"] - t["y"]) <= 4
                                 and s["observed"][k]["width"] <= t["width"] and s["observed"][k]["height"] <= t["height"]
                                 for k, t in s["frames"].items())
                    return s if placed else None
                return s if not s["mismatches"] else None
            return lab.wait_for(ready, timeout=6) or lab.state()

        def verify(label, windows=None, partition=True, slack_ok=False):
            lab.ensure_undisturbed()
            s = settled(windows, allow_mismatch=slack_ok)
            if not lab.check(s is not None, f"{label}: engine answers"):
                return None
            area, frames, observed = s["area"], s["frames"], s["observed"]
            lab.check(sorted(frames) == sorted(observed), f"{label}: every target window is on screen ({len(frames)})")
            if not slack_ok:
                lab.check(not s["mismatches"], f"{label}: drawn frames equal targets (mismatches {s['mismatches']})")
            if partition and frames:
                # A uniform 1-point outline macOS 26 draws around some windows (the window
                # server's bounds exceed the Accessibility frame by one point on every side) is
                # masked, as shadows are (plan §4.5); anything else counts.
                ax = s.get("accessibility") or {}
                def drawn(key, r):
                    a = ax.get(key)
                    ring = a and r["x"] == a["x"] - 1 and r["y"] == a["y"] - 1 and r["width"] == a["width"] + 2 and r["height"] == a["height"] + 2
                    return a if ring else r
                rects = [drawn(k, r) for k, r in observed.items()]
                overlaps = [(a, b) for i, a in enumerate(rects) for b in rects[i + 1:] if intersects(a, b)]
                lab.check(not overlaps, f"{label}: no overlaps")
                lab.check(all(inside(r, area) for r in rects), f"{label}: inside the area")
                if not slack_ok:
                    covered = sum(rect_area(r) for r in rects)
                    lab.check(covered == rect_area(area), f"{label}: no holes (covered {covered} of {rect_area(area)})")
            ok, violations = lab.invariants()
            lab.check(ok, f"{label}: every invariant holds {violations if not ok else ''}")
            return s

        live = json.loads(lab.tessera("doctor").stdout)
        usable = live["displays"][0]["visibleFrame"]
        a = open_window(one, "a")
        # One app alone: the bottom window may stop the Dock's point short, so wait for the
        # window, not for an exact match.
        first = lab.wait_for(lambda: (lambda st: st if st and len(st["frames"]) == 1 and sorted(st["frames"]) == sorted(st["observed"]) else None)(lab.state()), timeout=6)
        lab.check(first is not None and first["area"]["height"] == usable["height"],
                  f"one app alone does not teach an edge clamp (audit C4): area {first and first['area']}, usable {usable}")
        z = open_window(two, "z")
        s = verify("two apps: the Dock clamp is learned from both", 2)
        if s:
            lab.check(0 <= usable["height"] - s["area"]["height"] <= 3 and s["area"]["width"] == usable["width"],
                      f"tiling area {s['area']} is the usable area {usable} minus a 0-3 pt clamp")
        b = open_window(one, "b")
        s = verify("three windows stacked on the portrait monitor", 3)
        if s:
            heights = sorted(r["height"] for r in s["observed"].values())
            lab.check(sum(heights) == s["area"]["height"] and heights[-1] - heights[0] <= 1, f"three equal rows: {heights}")

        tall = open_window(one, "tall", minSize={"width": 300, "height": 1100})
        s = lab.wait_for(lambda: (lambda st: st if st and str(tall) in st["facts"] else None)(lab.state()), timeout=6)
        s = verify("a window with a 1100-point minimum height", 4)
        if s:
            lab.check(s["observed"].get(str(tall), {}).get("height", 0) >= 1100, f"minimum honoured: {s['observed'].get(str(tall))}")
            lab.check(str(tall) in s["facts"], f"minimum learned: {s['facts'].get(str(tall))}")
        one.call({"op": "close", "id": "tall"})
        verify("after closing it, the space is given back", 3)

        grid = open_window(one, "grid", minSize={"width": 60, "height": 40}, quantum={"width": 7, "height": 17})
        s = verify("a terminal-like grid window", 4, slack_ok=True)
        if s:
            tile = s["frames"][str(grid)]
            drawn = (s.get("accessibility") or {}).get(str(grid)) or s["observed"][str(grid)]
            print(f"     grid: window server {s['observed'][str(grid)]}, Accessibility {drawn}")
            lab.check(0 <= tile["height"] - drawn["height"] < 17 and 0 <= tile["width"] - drawn["width"] < 7,
                      f"grid slack stays inside the tile: tile {tile} drawn {drawn}")
        one.call({"op": "close", "id": "grid"})
        verify("grid closed", 3)

        # Pause: a window moved by hand stays; resume puts it back.
        lab.check(lab.tessera("pause").returncode == 0, "pause answers")
        one.call({"op": "setFrame", "id": "a", "frame": {"x": 150, "y": 400, "width": 500, "height": 500}})
        time.sleep(0.8)
        s = lab.state()
        lab.check(s is not None and s["observed"].get(str(a)) == {"x": 150, "y": 400, "width": 500, "height": 500},
                  "paused: the window stays where it was put")
        lab.tessera("resume")
        verify("resumed: tiled again", 3)

        lab.tessera("workspace", "2")
        d = open_window(two, "d")
        s = verify("group 2 inside the same native desktop", 1)
        if s:
            lab.check(sorted(s["hidden"]) == sorted([a, b, z]), f"group 1 hidden: {s['hidden']}")
            lab.check(s["observed"].get(str(d)) == s["area"], "the only window of group 2 fills the area")
        journal = json.load(open(os.path.join(lab.state_dir, "journal.json")))
        lab.check(sorted(map(int, journal["hidden"])) == sorted([a, b, z]), f"hidden windows journaled first: {sorted(journal['hidden'])}")

        lab.tessera("workspace", "back-and-forth")
        s = verify("back to group 1", 3)
        journal = json.load(open(os.path.join(lab.state_dir, "journal.json")))
        lab.check(sorted(map(int, journal["hidden"])) == [d], f"restored windows left the journal: {sorted(journal['hidden'])}")

        lab.tessera("focus", "--window-id", b)
        lab.tessera("fullscreen")
        s = lab.wait_for(lambda: (lambda st: st if st and st["observed"].get(str(st.get("focused"))) == st["area"] else None)(lab.state()), timeout=5)
        lab.check(s is not None, "Tessera full screen covers the desktop")
        lab.tessera("fullscreen")
        verify("full screen off: tiling restored", 3)

        lab.tessera("layout", "monocle")
        s = settled(2, allow_mismatch=False)
        lab.check(s is not None and all(r == s["area"] for r in s["observed"].values()) and len(s["hidden"]) == 2,
                  f"monocle: two windows over the whole area, the third and group 2 hidden ({s and s['hidden']})")
        before = (lab.state() or {}).get("focused")
        for direction in ("down", "up"):
            lab.tessera("focus", direction)
            moved = lab.wait_for(lambda: (lambda st: st if st and st.get("focused") != before else None)(lab.state()), timeout=2)
            if moved:
                break
        lab.check(bool(moved), "directional focus moves in monocle (audit D1)")
        lab.tessera("layout", "tiles")
        verify("back to tiles", 3)

        lab.tessera("move", "right")
        s = verify("move right splits the portrait column", 3)
        if s:
            widths = sorted(r["width"] for r in s["observed"].values())
            lab.check(set(widths) == {s["area"]["width"] // 2}, f"two equal columns: {widths}")
        lab.tessera("resize", "width", "+100")
        s = verify("resize width +100", 3)
        if s:
            widths = sorted(r["width"] for r in s["observed"].values())
            lab.check(640 in widths and 440 in widths, f"columns 640/440: {widths}")
        lab.check(lab.tessera("resize", "width", "9223372036854775807").returncode != 0, "a huge resize is refused (audit B2)")
        lab.tessera("balance-sizes")
        s = verify("balanced", 3)

        # Resize by hand: drag the bottom edge of the top-left window down; the column shares it.
        if s:
            top_left = min(s["frames"], key=lambda k: (s["frames"][k]["x"], s["frames"][k]["y"]))
            f = s["frames"][top_left]
            edge = f["y"] + f["height"] - 1
            time.sleep(0.5)
            lab.drag(f["x"] + f["width"] // 2, edge, f["x"] + f["width"] // 2, edge + 200)
            grown = lab.wait_for(lambda: (lambda st: st if st and not st["mismatches"]
                                          and st["frames"][top_left]["height"] >= f["height"] + 150 else None)(lab.state()), timeout=5)
            final = lab.state() or {}
            lab.check(grown is not None, f"a hand resize of the bottom edge is kept: {f} → {final.get('frames', {}).get(top_left)}")
            s = verify("after the hand resize", 3)
            lab.tessera("balance-sizes")
            s = verify("balanced again", 3)

        # Drag a window by its title bar onto another: they swap.
        if s:
            ids = sorted(s["frames"], key=lambda k: (s["frames"][k]["x"], s["frames"][k]["y"]))
            first_id, last_id = ids[0], ids[-1]
            f1, f2 = s["frames"][first_id], s["frames"][last_id]
            time.sleep(0.5)  # let the balance settle: a write during the press cancels the drag
            lab.drag(f1["x"] + f1["width"] // 2, f1["y"] + 12, f2["x"] + f2["width"] // 2, f2["y"] + f2["height"] // 2)
            after = lab.wait_for(lambda: (lambda st: st if st and st["observed"].get(first_id) == f2 else None)(lab.state()), timeout=5)
            final = lab.state() or {}
            lab.check(after is not None and after["observed"].get(last_id) == f1,
                      f"dragged window and drop target swapped: {first_id} {f1}→{final.get('observed', {}).get(first_id)}, {last_id} {f2}→{final.get('observed', {}).get(last_id)}")
            verify("after the drag", 3)

        # Re-tile: hidden groups gathered into view, Tessera stays active.
        lab.tessera("workspace", "2")
        lab.wait_for(lambda: (lambda st: st if st and len(st["hidden"]) == 3 else None)(lab.state()), timeout=5)
        lab.tessera("retile")
        gathered = lab.wait_for(lambda: not json.load(open(os.path.join(lab.state_dir, "journal.json")))["hidden"], timeout=5)
        lab.check(bool(gathered), "re-tile: every hidden window back in view and the journal emptied")
        stats = lab.tessera("debug", "stats").stdout
        lab.check("status: active" in stats, "re-tile never pauses Tessera")
        verify("after re-tiling everything", 4)
    except KeyboardInterrupt:
        lab.check(False, "interrupted", infra=True)
    except Disturbed as reason:
        lab.check(False, f"stopped: the owner is using the Mac ({reason})", infra=True)
    finally:
        area = (lab.state() or {}).get("area")
        lab.stop_engine()
        if area:
            parked = [line for line in lab.tool("parked", area["x"] + area["width"] - 2, area["y"] + area["height"] - 2).split("\n") if line]
            lab.check(not parked, f"after SIGTERM no window is left in the hiding corner: {parked}")
        code = lab.finish()
    return code


def main():
    codes = [run_once() for _ in range(runs_from_arguments())]
    print(f"\nruns: {len(codes)}, passed: {codes.count(0)}")
    return max(codes)


if __name__ == "__main__":
    sys.exit(main())
