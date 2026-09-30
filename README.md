<p align="center"><img src="assets/brand/lockup.svg" alt="tessera" width="320"></p>

A tiling window manager for macOS that never leaves holes.

Tessera keeps every tiled window where the layout says it is and proves it by measuring the
frames the window server actually draws, not the ones it asked for. It began as a replacement
for [AeroSpace](https://github.com/nikitabobko/AeroSpace), which on portrait monitors sometimes
corrupts its layout and leaves empty space; `docs/plan/` traces each cause to the design that
removes it.

> Status: **alpha**, used daily on one portrait monitor. One screen is tiled (others are left
> alone). Free and open source (MIT). See `docs/audit/` for the maturity audit and what remains.

## What it does

- Tiles every ordinary window of each macOS desktop (Mission Control), each desktop on its own.
  Dialogs, panels and fixed-size windows float; your own float/tile choice is kept.
- Learns what each window accepts (minimum, maximum, size grid) from what it refuses, and
  re-solves so there is never a hole or an overlap. Remembers it per app for 30 days.
- Layouts: tiles (side by side / stacked, rotating with the monitor), accordion, maximized, and
  Tessera full screen (one window over the desktop, the tiling kept behind).
- Mouse: drag a window onto another to swap them (the target is highlighted); resize a window
  and its neighbour gives or takes the space (the height in a column, the width in a row; what
  the tiling cannot express goes back). A window only floats when you ask (⌃⌥⇧Space).
  Drag a floating window onto the tiling and it joins it above or below the window under the
  pointer (the slot is highlighted); hold ⌥ while dropping to keep it floating. Dialogs and
  panels always float.
- When windows cannot all fit (apps with large minimum sizes), the rest stay tiled and the
  largest floats, centred, for you to move or resize; nothing is ever stacked at full size.
- Minimising, hiding and native full screen always work; Tessera re-tiles around them.
- Never loses a window: every window it hides is journaled first and restored on quit, crash
  (next start) or "Gather all windows".

## Install

Requires macOS 15.2 or later.

**Download.** Get [`Tessera.dmg`](https://github.com/rrios-dev/tessera/releases/latest/download/Tessera.dmg),
open it and drag Tessera onto Applications, then open it from there. The app and the disk image
are signed with a Developer ID and notarized by Apple. A plain `Tessera-<version>.zip` sits next
to it in the [latest release](https://github.com/rrios-dev/tessera/releases/latest) for scripts.
To start it at login and have it restart after a crash:

```bash
/Applications/Tessera.app/Contents/MacOS/tessera service install --binary /Applications/Tessera.app/Contents/MacOS/tessera
```

**From source** (Xcode 26, Swift 6.2):

```bash
scripts/install.sh      # builds, signs (Developer ID if you have one, else ad hoc), installs the app and the login service
```

Then allow Tessera in System Settings › Privacy & Security › Accessibility. Tessera waits for the
permission and starts by itself when it is granted.

## Keyboard

Every shortcut uses Control+Option (Control+Option+Command while VoiceOver is on). Hold ⌃⌥ for a
moment to see them all, or run `tessera keys`.

| Keys | Action |
|---|---|
| ⌃⌥H J K L or arrows | Focus left, down, up, right |
| ⌃⌥⇧H J K L or arrows | Move the window |
| ⌃⌥1…9 | Go to desktop 1…9 |
| ⌃⌥Tab | Back to the previous desktop |
| ⌃⌥F | Tessera full screen |
| ⌃⌥T / A / M | Tiles / accordion / maximized |
| ⌃⌥R | Rotate the orientation |
| ⌃⌥⇧Space | Float / tile the window |
| ⌃⌥B | Balance sizes |
| ⌃⌥. and ⌃⌥, (⇧ for height) | Wider / narrower |
| ⌃⌥P | Pause / resume Tessera |

Jumping to a desktop uses macOS's own shortcuts: turn on "Switch to Desktop N" in System
Settings › Keyboard › Keyboard Shortcuts › Mission Control for instant jumps (otherwise Tessera
steps with "Move left/right a space"). Tessera never changes those settings itself.

## Menu bar

The icon shows the desktop number. The menu lists the desktops, the layouts (with their keys),
Pause, Re-tile all windows (every ordinary window back in the tiling, resumes if paused), Revert to the original layout (first 10 minutes), Forget learned
sizes, Reload configuration, Recent activity and Quit (which restores every hidden window). Tessera pauses by
itself while Stage Manager or another tiling window manager (AeroSpace, yabai, Amethyst) runs.

## Configuration

Optional: `~/.config/tessera/tessera.local.toml` — gaps, default layout, overflow policy, apps to
exclude or float, shortcut overrides. See `docs/configuration.md`.

## Command line

```bash
tessera focus left | move right | workspace 2 | layout monocle | fullscreen | balance-sizes | resize width +50
tessera pause | resume | retile | reload-config | revert-layout | forget-sizes
tessera debug stats | state | activity | check
tessera service install | uninstall | status | restart
tessera doctor --output fixture.json          # environment capture, identifiers redacted
```

Operating details, recovery and logs: `docs/RUNBOOK.md`.

## Development

```bash
swift build && swift test                     # 150+ tests: core, fakes-driven engine, IPC, config
swift run -c release tessera-bench --check    # plan §11 budgets and baselines
swift run -c release tessera-bench model      # 10⁶ random events, every invariant checked
scripts/gate.sh                               # everything above plus the repository rules
python3 spikes/S1-single-monitor/live.py      # live sandbox on real windows
```

| Path | What lives there |
|---|---|
| `Sources/TesseraCore` | Pure model, solver, invariants. Standard library only. |
| `Sources/TesseraPorts` | The interfaces between the engine and macOS. |
| `Sources/TesseraPlatform` | The live macOS implementation (Accessibility, window server, SkyLight read-only). |
| `Sources/TesseraFakes` | A deterministic fake macOS for engine tests. |
| `Sources/TesseraEngine` | Reconciliation, journal, desktops, keys, IPC. |
| `Sources/TesseraAppUI` | Menu bar, on-screen notices, drop highlight, shortcut overlay. |
| `Sources/TesseraConfig` | Configuration, keymap, AeroSpace importer. |
| `Sources/tessera` | The command-line tool and the service. |
| `Sources/DummyWindowApp`, `tessera-labtools` | Test windows and live-test helpers. |
| `docs/` | Plan (Spanish), ADRs, invariants, runbook, audits. |

Code and documentation are in English; what a person reads on screen is Spanish or English
(`docs/glossary.md`). Window titles are never read.

## License

MIT. See `LICENSE` and `NOTICE.md`.

Made by [Roberto Ríos](https://www.rrios.dev), full-stack developer in Spain. Tessera has its own page at [tessera.rrios.dev](https://tessera.rrios.dev).
