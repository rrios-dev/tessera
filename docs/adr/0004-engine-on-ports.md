# 0004 — The engine runs on ports; safety rules that came with it

Status: accepted (2026-09-25, from the maturity audit)

## Context

The maturity audit (docs/audit/2026-09-25-maturity-audit.md) graded the engine 4/10: the code
most likely to lose or misplace windows (journal, reconciliation, learning) had no tests,
because it called macOS directly.

## Decision

1. **Ports.** The engine sees macOS only through `SystemPort` and `AppDriver`
   (TesseraPorts). `LivePlatform` implements them with Accessibility, CGWindowList and read-only
   SkyLight; `FakePlatform` simulates apps, windows with minimums/maximums/grids, Spaces, the Dock
   clamp, permissions, Secure Input and symbolic hotkeys, deterministically. Engine behaviour is
   tested against the fake; the live suite checks the same behaviour on real windows.
2. **The journal is the source of truth for hidden windows.** An entry is written before a
   window moves and removed only when a read-back shows the window back (or it no longer
   exists). Unconfirmed entries survive quit and are restored by a rescue sweep.
3. **Nothing is learned from a failed write.** Every Accessibility call reports its outcome; a
   refusal is re-read after the window settles; limits imposed by the display are not window
   limits; two contradictions drop a fact.
4. **Loops are bounded.** More than six refused writes to one window within five seconds backs
   it off for 60 s, doubling to five minutes. Successful writes never count (a burst of commands
   is not a loop — found live).
5. **The edge clamp needs two apps to agree**, is capped at 3 points and stored per screen
   arrangement.
6. **Synthesized keys are guarded**: never under Secure Input, never over the login window, only
   when the matching Mission Control shortcut is enabled, only for desktops 1…N.

## Consequences

- 150+ tests cover the engine's riskiest paths; a million-event model run checks the core.
- The AppKit UI is a separate target behind `EngineUI`; tests record what it would show.
