# Efficiency audit — 2026-09-25

Owner's Mac: Mac Studio M2 Max, macOS 26.6.2, one LG 1080×2560 portrait display, 11 managed apps.
Every figure below was measured, not estimated. Tools, all in the repo:

| Tool | Measures |
|---|---|
| `swift run -c release tessera-bench` | Solver, render and reducer time, 10–200 windows, against plan §11 |
| `spikes/perf/idle.py release 90` | Idle cost of a dry-run engine next to the owner's: CPU from accumulated CPU time, work counters (`tessera debug stats`), footprint, threads |
| `spikes/perf/active.py` | Per operation: latency to settle, AX writes and reads, scans, window-list copies, SkyLight calls, renders |
| `spikes/S1-single-monitor/close-latency.py` | Time for a closed window's space to be given back, 10 runs |

## Core (release)

| Windows | Solve p50 | Solve p99 | Render p99 | Reduce p99 |
|---|---|---|---|---|
| 10 | 0.021 ms | 0.051 ms | 0.011 ms | 0.012 ms |
| 100 | 0.203 ms | 0.238 ms | 0.101 ms | 0.112 ms |
| 200 | 0.588 ms | 0.684 ms | 0.193 ms | 0.197 ms |

Plan gate: solver p99 < 1 ms for 100 windows — met with 4× margin.

## Idle (release, dry-run engine, 90 s, no user activity)

| | Before | After |
|---|---|---|
| CPU | 0.378 % | 0.000 % (below `ps` resolution) |
| Window-list copies / min | 250 | 5.3 |
| SkyLight calls / min | 203 | 9.3 |
| AX reads / min | 430 | 6 |
| App scans / min | 27 | 2 |
| Footprint | 8.2 MB | 7.7 MB |

With the owner working (switching Spaces, focusing apps) the engine measured 0.067 % CPU.

## In use (release, sandbox with 3 windows)

| Operation | Latency | AX writes |
|---|---|---|
| Move (split column) | 44 ms | 7 |
| Resize / balance | 31–32 ms | 5 |
| Tessera full screen on / off | 30 / 17 ms | 3 |
| Workspace switch, hide / show 3 | 17 / 32 ms | 6 / 3 |
| Close a window | 23 ms (10 runs: median 36, worst 45) | 1 |
| A native Space switch | — | 11 scans (one per app), was 33 |

## What was wrong

1. **Scan loops.** The audit re-scanned every app with a tiled window not on screen, and every
   scan ended with an audit: scans every 2 s while nothing happened. Now an app is re-read only
   when one of its windows *stops* being drawn, once.
2. **Every move echoed as a full scan.** Tessera's own writes came back as "moved/resized"
   notifications that re-read the whole app (≈15 AX calls, 3 window-list copies per window
   moved). Moves now carry the window id: only that window is read, and echoes of Tessera's own
   writes are ignored.
3. **A 2 s timer doing three system-wide window-list copies.** Now one query over the windows
   Tessera tracks (`CGWindowListCreateDescriptionFromArray`), every 2 s only for 10 s after
   activity and every 30 s otherwise; Space and screen checks are event-driven.
4. **A disk write on every render.** The journal is written only when it changes.
5. **Redundant AX work per write and read.** Writes send only what changes (position alone,
   size alone, or size-position-size); reads use one `AXUIElementCopyMultipleAttributeValues`
   and cache per-window traits; the enhanced-UI flag is cached per app; the focused window is
   read on the app's queue instead of blocking the main thread.
6. **Close notifications not coalesced**, **SkyLight read twice per window per scan**, **the
   status item querying SkyLight on every render**, **`accept` spinning on errors**: fixed.

A regression found by the live tests while doing this: `CGWindowListCreateDescriptionFromArray`
takes raw window ids, not `NSNumber`s. With `NSNumber`s it returns nothing and every audit
forgot every window. `Tests/TesseraPlatformTests` now checks the query against the live window
server.

## Not changed, and why

- Solver micro-optimisations (memoised measuring, fewer small allocations): the solver is 4×
  under its budget at 100 windows in release.
- The owner was running a **debug** build (`swift run`). Release is what the figures above use
  and what should be run.
