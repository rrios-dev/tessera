# 0001 — Native Spaces tile independently; Tessera workspaces nest inside them

Status: accepted (owner, 2026-09-25)

## Context

The owner asked for one monitor to work perfectly "with macOS virtual desktops, with the
normal desktop and with both combined", and asked whether native full-screen apps can tile.

The plan (D3) emulated workspaces only. That cannot see macOS Spaces: with public API alone
a window's Space is unknown until the window is seen on screen, and two empty Spaces are
indistinguishable.

## Evidence (owner's Mac, macOS 26.6.2)

Read-only SkyLight calls, no SIP change:

- `SLSGetActiveSpace` → 3; `SLSCopyManagedDisplaySpaces` → Space 3 (type 0, desktop) and
  Space 183 (type 4, native full screen) on the LG display.
- `SLSCopySpacesForWindows` over 88 layer-0 windows → 8 on Space 3, 2 on Space 183, 78 on
  none (helper windows that never show).
- A native full-screen window (pid 83728, window 5842, Space 183): `AXFullScreen = true`,
  `kAXPosition` **not settable**, `kAXSize` settable, `AXFullScreen` settable.

## Decision

1. **Every desktop Space tiles on its own.** Each native Space has its own tree(s); switching
   Space with Mission Control or Ctrl-arrows shows that Space's tiling.
2. **Tessera workspaces nest inside a Space.** A Space starts with one workspace ("1"); the
   `workspace N` command creates and switches workspaces *within the current Space*, hiding the
   others in a corner. One Space with several workspaces behaves like AeroSpace; several Spaces
   with one workspace each is tiling over native desktops; both can be mixed.
3. **Native full-screen Spaces are left alone.** Their window's position is locked and moving
   other windows into that Space needs SkyLight writes that require SIP disabled. Tessera
   never touches a full-screen Space; the window returns to its desktop's tiling when it
   leaves full screen.
4. **Tessera full screen** (`fullscreen`, Control-Option-F) is the tileable alternative: the
   window covers the whole desktop and the tiling stays behind it. Because `AXFullScreen` is
   settable, a later option can turn the green button into Tessera full screen.
5. **SkyLight is read-only** and isolated in `SpaceService`: active Space, Spaces per display,
   Space of a window. Never used to move windows or switch Spaces. If a symbol is missing,
   the engine falls back to a single implicit Space.

## Consequences

- D3 and D7 of the plan are amended: emulated workspaces remain, but inside native Spaces,
  and D7's private-API list gains three read-only SkyLight calls.
- The live test refuses to run on a full-screen Space, where Tessera by design does nothing.
