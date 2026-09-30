# 0003 — Native desktops mode: Tessera's workspaces are Mission Control's desktops

Status: accepted (owner, 2026-09-25)

## Context

The owner asked for the desktops Tessera switches between to be macOS's own (Mission Control),
and for native full-screen apps to be tiled too. ADR 0001 had Tessera workspaces nested inside
each native desktop, hidden in a corner when not shown.

## Evidence (spike S12, owner's Mac, macOS 26.6.2)

- "Move left/right a space" (Control-Arrow) is on by default; "Switch to Desktop N" is off.
  With the owner's consent Tessera enabled Control-1…9 in `com.apple.symbolichotkeys`
  (backup of the previous values in `spikes/S12-native-spaces/symbolichotkeys-before.plist`).
- Posting Control-Arrow: one desktop in **~770 ms**. Posting Control-N: **~270–290 ms**.
- Carrying a window to another desktop:
  - minimise, jump, restore: **fails**, macOS restores the window on its original desktop;
  - hold the title bar with synthesized mouse events and jump: **1 success in about 20 tries**,
    including drag distances of 4–40 pt, holds of 150–800 ms, both event taps (HID, session)
    and all event sources (HID state, combined, none). A person dragging a window while
    pressing Control-N does move it.
- Native full-screen windows: position not settable (ADR 0001); a normal window cannot be put
  into a full-screen Space without SkyLight writes that need SIP disabled.

## Decision

1. **Native mode is the default.** `workspace N` (Control-Option-N, or macOS's own Control-N)
   jumps to Mission Control desktop N; `workspace back-and-forth` returns to the previous one.
   Nothing is hidden in corners, so Mission Control and the system transition show everything.
2. **Every desktop tiles on its own**, as in ADR 0001.
3. **Moving a window to another desktop is done by the user** (drag it while pressing Control-N,
   or drop it on a desktop in Mission Control). Tessera re-tiles both desktops: the window leaves
   the source tree when its app stops listing it on that desktop, and joins the target tree when
   that desktop is shown. `move-node-to-workspace` in native mode beeps and explains instead of
   pretending.
4. **Emulated workspaces stay available** (`--emulated-workspaces`, later a setting) for users who
   want keyboard moves between workspaces; they cannot be Mission Control desktops.
5. **Native full-screen apps are not tiled.** Tessera full screen (Control-Option-F) remains the
   tileable alternative.

## Consequences

- The synthesized-carry code was removed; this record keeps the measurements in case a later
  macOS changes the behaviour.
- The live test `spikes/S12-native-spaces/native.py` checks jumps and that tiling survives them.
- **Reversibility (audit E12).** The shortcuts were changed by hand once, with consent, during
  the spike. `scripts/restore-hotkeys.sh` puts the saved values back (`defaults import` +
  `activateSettings -u`). Tessera never writes `com.apple.symbolichotkeys`; when direct jumps
  are off it steps with Control-Arrow if that shortcut is on, and otherwise explains where to
  turn them on instead of guessing (a synthesized Control-Arrow with the shortcut off would reach
  the focused app).

