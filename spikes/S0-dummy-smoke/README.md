# S0 — DummyWindowApp smoke test

Not a plan spike: a check that the harness's test windows behave before S1 relies on them.

```bash
swift build
python3 spikes/S0-dummy-smoke/run.py
```

## Run of 2026-09-25 (owner's Mac, macOS 26.6.2, LG 1080×2560 portrait, AeroSpace 0.20.3 running)

**0 failing checks.** Every window's reported frame matched `CGWindowList`, and every
constraint held both after opening and after resizing through the Accessibility API.

| Window | AX size request | Accepted | AX write |
|---|---|---|---|
| grid (min 60×40, quantum 7×17) | 541×801 | 536×788 | 0.43 ms |
| bounded (min 400×300, max 700×900) | 100×100 | 400×300 | 1.09 ms |
| bounded | 2000×2000 | **540**×900 | 3.58 ms |
| aspect (9:19) | 450×100 | 450×950 | 1.05 ms |
| rigid | 200×200 | 500×500 (refused) | 0.35 ms |

The self-resizing window reached 333×222 after 800 ms as scheduled.

## Findings

1. **An AX size write goes through `NSWindow.setFrame(_:display:)`**, so the override in
   `ConstrainedWindow` enforces constraints whichever path changes the frame.
2. **AppKit clamps AX size requests to the screen edge.** `bounded`, at x = 540 on a
   1080-wide screen, accepted 540 wide instead of its 700 maximum: the window was kept
   inside the display. This is the clamp spike S2 must model per arrangement; the solver
   can never assume a window accepts a size that crosses a display edge.
3. **AeroSpace ignored the test windows** — their frames never changed. *Corrected later
   the same day:* the cause is not the missing bundle identifier but the missing native
   full-screen button, which AeroSpace's heuristics read as "dialog, float it". Once the
   windows gained the button (`fullScreenCapable`, now the default), AeroSpace tiled them.
   The live sandbox relies on this: its windows omit the button so AeroSpace leaves them
   alone, and Tessera tiles them with the test-only `--tile-all`.
4. AX writes cost 0.3–3.6 ms each in this run, inside the 0.5–5 ms range the plan's
   performance gates assume (§11).
