# Invariants

What must always be true. Each invariant says where it is checked: **model** invariants by
`Invariants.check(world, render:area:)` in TesseraCore (unit tests, the model-based run of
`tessera-bench model`, and `tessera debug check` on the live engine); **engine** invariants by
`Engine.runtimeViolations` against what the window server draws (engine tests with the fake
platform, `tessera debug check`, the live suite). ★ marks the invariants the definition of done
requires in fakes *and* at runtime (plan §12).

| ID | Invariant | Checked |
|---|---|---|
| I1 | The tiles of a partition-mode workspace (tiles layout, no zoom, no overflow, no accordion, no gaps) cover the tiling area exactly, without overlap. | model, solver property tests (300k trees) |
| I1b | Every tile has a positive width and height and lies inside the area. | model |
| I2 | Seams are exact: neighbouring tiles share an edge (follows from I1 with integer geometry). | solver property tests |
| I3 | A container's weights sum to exactly 10⁶ ppm and none is below the floor `min(5 %, 1/(2n))`. | model |
| I4 | Trees are normalised: no nested container with fewer than two children; normalising is idempotent. | model |
| I5 | Every window is in exactly one place: a tiled window in one tree, a floating window in one floating list, both in the workspace its record names; minimised, app-hidden and native full-screen windows in none. | model |
| I5b | Only resizes, drops, balancing and tree edits change weights; focus, facts and Space changes never do. | model-based test |
| I6 | The reducer is deterministic: the same world, event and area give the same world. | model-based test |
| I7 ★ | A window Tessera hid shows at most a 2-point sliver of itself on the primary display (macOS never lets a window leave the screen entirely: the remnant *k* of plan §6.3). | engine |
| I8 | Focus and history are consistent: the focused window exists; each workspace's MRU holds only its own windows, once each; facts exist only for known windows. | model |
| I9 ★ | Every settled tiled window of the visible workspace is drawn exactly at its planned frame, except in a terminal state (refused twice, backed off) that the engine reports. | engine (alignment check on every audit tick, one retry, bounded) |
| I10 ★ | Window states are the enumerated ones (tiled, floating, auto-floated as a derived flag, minimised, app-hidden, native full screen); a zoomed window is a tiled window of its own tree; a user's float/tile choice wins over heuristics. | model |
| I11 ★ | Every window Tessera hid has a journal entry with its original frame, written before it moved, removed only after a confirmed restore or when the window no longer exists. | engine (+ journal tests) |
| I12 | Every Space has at least one workspace, names are unique, and the active one exists. | model |
| I13 | Placed windows lie inside the tiling area, except windows whose minimum exceeds it and the `allow` overflow policy. | model |
| I14 | Assignment is deterministic: a window belongs to the Space macOS reports (the active one when it is on several). | engine (single monitor) |
| I15 | An empty workspace that is neither shown nor the previous one, and holds no minimised or hidden window, is pruned. | model |
| I16 | The render names only windows of the visible workspace; raise order has no duplicates; nothing is both placed and hidden; every tiled window is placed or hidden; windows of other workspaces are hidden. | model |
| I17 | Per-app rules from the configuration (exclude, float) are applied to every window of the app. | engine tests |
| I18 | Journal entries of windows that no longer exist are dropped; entries from another boot are discarded. | engine tests |
| I19 | Monocle shows the front window over the whole area and at most one more under it; the rest are hidden. | model |

## Where they run

- `swift test`: every model invariant after every event of 24 seeded sequences × 400 events;
  engine invariants in the fake-platform suite.
- `swift run -c release tessera-bench model 1000000`: one million events (13 s on the Mac Studio).
- `tessera debug check`: the running engine, now; non-zero exit on any violation.
- `spikes/S1-single-monitor/live.py`: `debug check` after every step on real windows.
