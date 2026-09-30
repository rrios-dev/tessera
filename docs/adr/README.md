# Decision records

One file per spike and per load-bearing decision: `NNNN-short-title.md`, with
status (proposed, accepted, superseded), context, options, decision, and the evidence
that supports it. Spike records end in go / no-go / fallback.

| Spike | Question | Status |
|---|---|---|
| S1 | Does closed-loop reconciliation leave zero undetected holes on the owner's portrait monitor? | in progress: live sandbox passing (spikes/S1-single-monitor) |
| S2 | What does the window server clamp, on which arrangements, and where is a safe hiding corner? | not started |
| S3 | Per-app actor executors: memory, isolation on macOS 26 and 15.2, SIGSTOP behaviour | not started |
| S4 | Are Option-only hotkeys delivered on 26 and 15.2; which permission does each event tap need? | not started |
| S5 | Is `CGVirtualDisplay` reliable enough for the harness? | not started |
| S6 | Lossless TOML CST round-trip over 200 configurations | not started |
| S7 | Focus through public API vs SkyLight; floating-window z-order | not started |
| S8 | Which signals report usable-area changes (Dock, menu bar)? | not started |
| S9 | Display identity on Apple Silicon for identical monitors | not started |
| S10 | Detecting windows on another native Space without private API | not started |
| S11 | Nightly runs in the `tessera-lab` account on the owner's Mac | not started |

## Decisions

- [0001](0001-native-spaces-and-workspaces.md) — Native Spaces tile independently; Tessera workspaces nest inside them.
- [0002](0002-learned-edge-clamp.md) — The edge clamp is measured, not hard-coded.
- [0003](0003-native-desktops-mode.md) — Native desktops mode: Tessera's workspaces are Mission Control's desktops.
- [0004](0004-engine-on-ports.md) — The engine runs on ports; journal, learning and input safety rules.
