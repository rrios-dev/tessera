#!/usr/bin/env python3
"""Measures how long Tessera takes to give a closed window's space back.

Sandboxed to two DummyWindowApp processes (two apps, so the Dock clamp is learned as in real
use): opens three tiled windows, closes the middle one, and polls `tessera debug state` every
10 ms until the two survivors are drawn at their new targets and cover the whole area.
Repeats ten times and prints the distribution."""
import os, statistics, sys, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from lab import Lab, Disturbed  # noqa: E402


def main():
    lab = Lab("S1-close-latency")
    if lab.start_kind != "desktop":
        print("needs a desktop Space"); return 2
    samples = []
    try:
        app1, one = lab.start_dummy("one")
        app2, two = lab.start_dummy("two")
        lab.start_engine("--only-pid", app1.pid, "--only-pid", app2.pid, "--no-hotkeys", "--tile-all", "--no-menu")
        apps = [one, two, one]
        for run in range(10):
            lab.ensure_undisturbed()
            ids = []
            for n in range(3):
                spec = {"id": f"w{run}-{n}", "frame": {"x": 100, "y": 200, "width": 500, "height": 400}, "fullScreenCapable": False}
                apps[n].call({"op": "open", "spec": spec})
                ids.append(f"w{run}-{n}")
            lab.wait_for(lambda: (lambda s: s and len(s["frames"]) == 3 and not s["mismatches"])(lab.state()), timeout=6)
            start = time.monotonic()
            apps[1].call({"op": "close", "id": ids[1]})
            elapsed = None
            while time.monotonic() - start < 4:
                s = lab.state()
                if s and len(s["frames"]) == 2 and not s["mismatches"] and sorted(s["frames"]) == sorted(s["observed"]):
                    if sum(r["width"] * r["height"] for r in s["observed"].values()) == s["area"]["width"] * s["area"]["height"]:
                        elapsed = (time.monotonic() - start) * 1000
                        break
                time.sleep(0.01)
            samples.append(elapsed)
            print(f"run {run + 1}: {'%.0f ms' % elapsed if elapsed else 'not within 4 s'}", flush=True)
            apps[0].call({"op": "close", "id": ids[0]})
            apps[2].call({"op": "close", "id": ids[2]})
            lab.wait_for(lambda: (lambda s: s is not None and not s["frames"])(lab.state()), timeout=4)
    except Disturbed as reason:
        lab.check(False, f"stopped: {reason}", infra=True)
    finally:
        done = sorted(s for s in samples if s is not None)
        if done:
            print(f"\nmedian {statistics.median(done):.0f} ms, worst {done[-1]:.0f} ms, {len(done)}/{len(samples)} within 4 s")
        lab.check(len(done) == len(samples) and len(samples) == 10, f"every close gave its space back within 4 s ({len(done)}/{len(samples)})")
        code = lab.finish()
    return code


if __name__ == "__main__":
    sys.exit(main())
