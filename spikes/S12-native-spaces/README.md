# S12 — native Spaces as Tessera's desktops

Question: can Tessera's workspaces be macOS's own desktops (Mission Control), switched and
moved between with public input only, on macOS 26? Outcome and measurements: ADR 0003.

| File | What |
|---|---|
| `native.py` | Live check (sandboxed, own state directory): `workspace 2` and `back-and-forth` switch desktops natively, invalid desktops never reach the keyboard, desktop 1 stays tiled after the round trip, the owner is returned to where they started. Needs two desktops and an idle Mac. |
| `switch.swift` | Measures Control-N and Control-Arrow switch times (≈280 ms and ≈770 ms per step). |
| `move.swift`, `carry2.swift` | The attempts to carry a window to another desktop with synthesized events (1 success in ≈20 on macOS 26): why moving is left to the user. |
| `symbolichotkeys-before.plist` | The owner's keyboard shortcuts before "Switch to Desktop N" was turned on; `scripts/restore-hotkeys.sh` restores them. |
| `engine.log` | Engine log of the spike run. |

```bash
swift build
python3 spikes/S12-native-spaces/native.py
```
