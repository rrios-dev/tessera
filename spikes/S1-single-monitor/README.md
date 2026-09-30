# S1 — single monitor, live

Two live checks on the owner's Mac (macOS 26.6.2, LG 1080×2560 portrait, Dock at the bottom).
Both compare Tessera's targets with the frames the window server actually draws.

```bash
swift build
python3 spikes/S1-single-monitor/live.py   # sandbox: Tessera manages only DummyWindowApp
python3 spikes/S1-single-monitor/real.py   # real apps: pauses AeroSpace, restores everything after
python3 spikes/S1-single-monitor/wait-and-run.py   # waits for a desktop with windows, runs both
```

Both refuse to run on a native full-screen Space (Tessera does nothing there by design) and
the real-app test needs a desktop with at least two visible windows.

## Result, 2026-09-25 afternoon

| Run | Checks | Failures |
|---|---|---|
| Sandbox (`live.py`) | 80 | 0 |
| Real apps (`real.py`) | 54 | 0 |

Covered: equal rows without holes; a learned 1,100-point minimum; a closed window giving its
space back; a terminal-like grid keeping its slack inside the tile; Tessera workspaces nested
in the native Space (hide, show, back-and-forth); Tessera full screen; move right; resize;
balance; accordion; monocle; SIGTERM restoring every hidden window.

## Result, 2026-09-26 (engine rebuilt on ports, commit after the maturity remediation)

| Run | Checks | Failures |
|---|---|---|
| Sandbox (`live.py --runs 3`, two DummyWindowApp processes, own state directory) | 3 × 127 | 0 |

New coverage: the Dock clamp learned only once two apps agree; pause/resume; group hiding
journaled before moving and cleared on confirmed restore; directional focus in monocle; a huge
resize refused; gather; every invariant (`tessera debug check`) after every step; the owner
returned to their Space. History: `spikes/results/S1-live.jsonl`.

Found by these runs and fixed: the loop guard counting successful writes; alignment rewrites of
windows that keep their own size (they drifted a point outside the area); a stale focus report
pulling the view into a hidden group; `debug state` answering from before a command; a window
whose first write was ignored left where it opened. macOS 26 draws a 1-point outline around
some windows (window-server bounds one point larger than the Accessibility frame on every
side); the suite masks that uniform ring, as the plan masks shadows.

## What the live runs found (all fixed)

1. macOS keeps windows 1 point off the Dock → learned edge clamp (ADR 0002).
2. Apps that close a window by ordering it out → retired when no longer listed nor drawn.
3. AX observer registration failing during app launch → retried, plus a discovery fallback.
4. The retry counter surviving hide/unhide → reset on both.
5. The usable area reading differently mid-transition between Spaces → re-read.
6. Two real apps needing 623 + 500 points side by side on a 1080-wide monitor → the
   container is reflowed into a stack instead of overlapping (property-tested on 20,000 trees).
7. Test-side: another window manager tiles any window with a native full-screen button, so
   the sandbox uses windows without it and `--tile-all`.
