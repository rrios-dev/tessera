# Configuration

`~/.config/tessera/tessera.local.toml` — optional, read at start and on "Recargar configuración".
A strict subset of TOML: sections, `key = value`, integers, booleans, strings and one-line lists
of strings. Errors name their line; unknown keys are warnings; the rest applies.

```toml
[general]
inner-gap = 8                 # 0…200 points between windows
outer-gap = 8                 # 0…200 points around the desktop
default-layout = "tiles"      # tiles | accordion | monocle
overflow = "float-largest"    # float-largest (default) | accordion | stack | allow
emulated-workspaces = false   # true: Tessera groups inside each desktop instead of macOS desktops

[apps]
exclude = ["com.apple.systempreferences"]   # never managed
float = ["us.zoom.xos"]                     # always floating

[keys]
# Any action from `tessera keys`, by name, to a chord or "none".
toggle-floating = "ctrl-alt-shift-space"
layout-accordion = "none"
```

Action names: `focus-left|right|up|down` (and `-arrow`), `move-…`, `workspace-1…9`,
`move-node-to-workspace-1…9`, `workspace-back-and-forth`, `fullscreen`, `layout-tiles`,
`layout-accordion`, `layout-monocle`, `toggle-orientation`, `toggle-floating`, `balance-sizes`,
`grow-width`, `shrink-width`, `grow-height`, `shrink-height`, `pause`.

With VoiceOver on, the default chords use Control+Option+Command instead of Control+Option
(VoiceOver's own modifier); overrides are taken as written.

## Overflow policies

When windows' minimums fit neither side by side nor stacked:

| Policy | Result |
|---|---|
| `float-largest` (default) | The window with the largest minimum becomes an ordinary floating window, centred once, then yours to move and resize; repeated until the rest fits. ⌃⌥⇧Space puts it back. |
| `accordion` | Overlapping strips (up to 4 windows), else `stack`. |
| `stack` | Every window over the whole container, the most recent in front. |
| `allow` | The split is kept and windows extend past the desktop. |

Tessera explains the first overflow of a workspace on screen.
