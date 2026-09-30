# 0002 — The edge clamp is measured, not hard-coded

Status: accepted (2026-09-25)

## Context

AeroSpace lays out every workspace with `height - 1` (`layoutRecursive.swift:9-11`), with a
comment about vertically stacked monitors and no measurement behind it.

## Evidence

On the owner's LG (1080×2560 portrait, Dock at the bottom, usable area 1080×2448 at y = 30),
a DummyWindowApp window asked for 1080×2448 and for 1080×2530 through the Accessibility API
came back 1080×**2447** both times: macOS keeps windows one point off the Dock. Asked for
2000 wide at x = 540, a window came back 540 wide: it is kept inside the display.

## Decision

The engine learns an inset per outer edge of the usable area. When a window whose target
touches an outer edge stops 1–3 points short there, twice in a row with the opposite edge in
place, the shortfall belongs to the screen: it is subtracted from the tiling area and the
layout is recomputed, so the partition is exact over the area windows can really reach.
The clamp resets when screen parameters change.

## Consequences

- The strip between the window and the Dock is outside the reachable area, not a hole; the
  no-holes check compares against the learned tiling area (`tessera debug state` → `area`).
- Spike S2 extends the same measurement to multi-monitor arrangements.
