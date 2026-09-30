#!/usr/bin/env python3
"""Live check of native-desktop mode: Tessera's workspaces are Mission Control's desktops.

Sandboxed to DummyWindowApp in its own state directory. Jumps between desktops 1 and 2 with
Tessera's commands, checks with SkyLight that macOS shows the right desktop and that desktop 1 is
still tiled after the round trip, and that invalid desktops never reach the keyboard. Returns the
owner to the Space they started on. Synthesizes keys, so it runs only on an idle desktop."""
import os, sys, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from lab import Lab, Disturbed  # noqa: E402


def main():
    lab = Lab("S12-native")
    desktops = [int(line.split()[0]) for line in lab.tool("spaces").split("\n") if line.endswith("desktop")]
    if len(desktops) < 2 or lab.start_desktop != 1:
        print("needs two desktops in Mission Control and to start on desktop 1"); return 2
    active = lambda: int(lab.tool("active-space").split()[0])
    try:
        app1, one = lab.start_dummy("one")
        app2, two = lab.start_dummy("two")
        lab.start_engine("--only-pid", app1.pid, "--only-pid", app2.pid, "--no-hotkeys", "--tile-all", "--no-menu")
        for dummy, wid in ((one, "a"), (two, "b")):
            dummy.call({"op": "open", "spec": {"id": wid, "frame": {"x": 100, "y": 200, "width": 500, "height": 400}, "fullScreenCapable": False}})
        s = lab.wait_for(lambda: (lambda st: st if st and len(st["observed"]) == 2 and not st["mismatches"] else None)(lab.state()), timeout=6)
        lab.check(s is not None, "two windows tiled on desktop 1")

        for bad in ("-100000000", "0", "17"):
            lab.tessera("workspace", bad)
        time.sleep(0.8)
        lab.check(active() == desktops[0], "invalid desktops never switch (audit B1)")

        lab.tessera("workspace", "2")
        lab.check(bool(lab.wait_for(lambda: active() == desktops[1], timeout=3)), "`workspace 2` jumps to desktop 2 natively")
        lab.tessera("workspace", "back-and-forth")
        lab.check(bool(lab.wait_for(lambda: active() == desktops[0], timeout=3)), "`workspace back-and-forth` returns to desktop 1")
        s = lab.wait_for(lambda: (lambda st: st if st and len(st["observed"]) == 2 and not st["mismatches"] else None)(lab.state()), timeout=5)
        lab.check(s is not None, "desktop 1 still tiled after the round trip")
        ok, violations = lab.invariants()
        lab.check(ok, f"every invariant holds {violations if not ok else ''}")
    except Disturbed as reason:
        lab.check(False, f"stopped: {reason}", infra=True)
    return lab.finish()


if __name__ == "__main__":
    sys.exit(main())
