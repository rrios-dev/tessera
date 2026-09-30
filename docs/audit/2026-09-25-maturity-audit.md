# Maturity audit — 2026-09-25 (HEAD cf9bfc2, 11 commits, ~5,000 LOC)

Four independent reviews of the code as it runs on the owner's Mac today — engineering and
reliability, security and privacy, product/UX/accessibility, QA/release/operations — consolidated
here. Every finding carries a proposed solution, the impact for the user, the effort (S ≤ 1 day,
M 1–3 days, L > 3 days) and a cost/benefit verdict. Facts were checked on the machine: the
running engine is ad-hoc signed (`codesign`: no TeamIdentifier), the journal is 0644, the socket
0600, the log has no timestamps, `swift test` passes 51 tests, and no Secure Input check exists
before synthesizing keys.

## 1. Grades (0–10)

| Area | Grade | One line |
|---|---|---|
| Core model and solver | **7.0** | Pure, integer, deterministic, property-tested (I1, I1b, I2, I3, I4, I6). Missing autoFloated, overflow policies, focus in overlapping layouts. |
| Engine / reconciliation | **4.0** | Happy path works and is measured; but facts are learned from failed writes, one refusal pattern loops forever, no runtime check that windows landed. |
| Platform integration | **6.0** | Per-app queues, timeouts, read-only SkyLight with fallback; observer thread blocks on AX, no second-monitor guard, AX errors discarded. |
| Concurrency safety | **6.5** | All `assumeIsolated` sites verified on the main thread; echo suppression correct. `@unchecked Sendable` relies on discipline. |
| Error handling and crash safety | **3.0** | Journal written before hiding (right), but erased before restores are confirmed; CLI input can trap the engine; no supervisor. |
| Security and privacy | **4.0** | Titles never read; 0600 socket + peer UID. But any same-user process can synthesize keystrokes and crash the engine; ad-hoc signature. |
| Test coverage | **4.5** | Core ≈ 8; engine, journal, reconciler, IPC handler, observer hub: 0 tests; fakes are a placeholder; I5, I5b, I7★, I8, I9★, I11★, I12–I18 not asserted. |
| Product / UX / accessibility | **2.5** | No onboarding, no shortcut discovery, silent failures, menu jumps to the wrong desktop, Control+Option collides with VoiceOver. |
| CI and release engineering | **1.0** | CI has never run (Forgejo has no macOS runner); no bundle, signing, version, LaunchAgent; started by hand with nohup. |
| Observability | **2.0** | `debug stats/state` are good; logging is stderr without timestamps, levels or rotation. |
| Documentation | **6.0** | Plan, ADRs and perf report are evidence-based; README stale ("nothing manages windows yet"); no runbook, no invariant catalogue. |
| **Overall** | **4.0** | **A credible alpha with an unusually good core.** Fit for the owner on one portrait monitor; not fit to hand to anyone else, and not yet fit to run unattended. |

## 2. Findings

Severity: **P0** loses or strands windows / crashes from local input; **P1** wrong behaviour the
user meets daily or a real security gap; **P2** quality, hygiene, roadmap. Verdict: **now** (this
week), **next** (before the week-22 checkpoint), **later**.

### A. Windows can be lost — P0

| ID | Finding (evidence) | Failure | Solution | Impact | Effort | Verdict |
|---|---|---|---|---|---|---|
| A1 | Journal erased without confirming each restore: `shutdown` skips unknown apps then `removeAll()`; `restoreJournal` clears right after firing async writes; AX lists only the visible Space (`Engine.swift:154-161, 774-783`; `AXApplication.swift:57`). | Monocle parks a window; the user switches desktop and quits, or Tessera is killed. The window stays at the corner and its original frame is gone. | Remove an entry only when the read-back matches the saved frame. Keep the rest and retry on every Space change, app launch and unhide (plan §8 rescue sweep). | Windows are never lost: the core trust property. | S–M | **now** |
| A2 | Test/perf engines share the owner's socket and journal: `Server.start` unlinks the path; `Journal.defaultURL` is fixed; `--dry-run` still runs `restoreJournal` and `shutdown` saves (`LineSocket.swift:64`; `Engine.swift:117,160`). Spike scripts use the default socket. | A benchmark run next to the owner's engine un-hides its windows and wipes the journal; a live test kills the owner's CLI. | `flock` on `engine.lock`, refuse a second instance; `--state-dir`/`TESSERA_HOME` for socket+journal+log; dry-run never touches the journal; connect-probe before `unlink`. | Owner safety while developing. | S | **now** |
| A3 | No supervisor: nohup, no `KeepAlive`, no crash-loop guard. | A crash in monocle leaves windows parked until the owner notices the missing menu item. | `SMAppService` agent, `KeepAlive{SuccessfulExit=false, Crashed=true}`, `ThrottleInterval 5`; 3 crashes/5 min → safe mode that restores and moves nothing. | MTTR from hours to seconds. | S–M | **now** |
| A4 | Journal integrity: 0644 in a 0755 dir; pid trusted across reboots; corrupt file silently becomes empty (`try?`). | Same-user tampering; stale pid+window id after reboot; silent data loss. | 0700/0600; store `kern.bootsessionuuid` and discard on mismatch; filter entries against `optionAll`; quarantine a corrupt journal and warn. | Integrity. | S | **next** |

### B. Crashes and injection from local input — P0/P1

| ID | Finding | Failure | Solution | Impact | Effort | Verdict |
|---|---|---|---|---|---|---|
| B1 | Workspace number not range-checked in native mode (`Engine.swift:530-534`); negative/zero pass; `NativeSpaces.swift:35` loops `abs(target-current)` posting keys. **Confirmed in code.** | `tessera workspace -100000000` from any same-user process: 10⁸ synthetic keystrokes on the main thread; `Int.min` traps. | Accept only `1...desktops.count` (cap 16); workspace-name grammar `^[0-9A-Za-z_-]{1,16}$`; cap arrow steps. | Removes a crash and a keystroke-flood primitive. | S | **now** |
| B2 | `resize` accepts any Int; `points * Weights.total` overflows (`CommandParser.swift:60`; `Reducer.swift:316`); `--gap` unbounded. | `tessera resize width 9223372036854775807` crashes the engine (and with A1, strands windows). | Clamp ±10 000; saturating arithmetic; bound gap. | No crash from bad input. | S | **now** |
| B3 | Key synthesis has no guards: no `IsSecureEventInputEnabled()` check, no check that Mission Control shortcuts 79/81 are enabled, no frontmost-app check (`NativeSpaces.swift:31-35`). **Confirmed.** | If the shortcuts are off, Control-Arrow reaches the focused app (word jumps in an editor). A hostile IPC client turns this into keystroke injection. | Post only when the matching symbolic hotkey is enabled; refuse under Secure Input or when `loginwindow`/`SecurityAgent` is frontmost (beep + log). | Removes the injection path. | S | **now** |
| B4 | Confused deputy: `getpeereid` checks only the UID. Any local process without TCC can use Tessera's Accessibility grant to focus/raise/move windows or jump desktops. Reads (`debug state`) leak nothing beyond what CGWindowList already exposes. | An unprivileged script brings a chosen app to the front as the user types (focus hijack). | After B7: audit token via `LOCAL_PEERTOKEN`, code-signature requirement for mutating verbs; keep reads open; rate-limit `focus` meanwhile. | Closes TCC laundering. | M | **next** |
| B5 | `LineSocket`: unbounded line buffer, thread per connection, no read timeout, every request `DispatchQueue.main.sync`. | GBs without newline → memory; thousands of idle connections → threads; `debug state` spam → hotkey lag. | 64 KiB line cap; ≤ 8 connections; `SO_RCVTIMEO` 5 s; one request per connection; throttle `state`. | Robustness. | S | **now** |
| B6 | `Rect(cg:)` traps on NaN/∞ on every AX/CG frame read (`EnvironmentProbe.swift:310-316`). | One app reporting a non-finite position kills the window manager. | Failable init with `isFinite`/`Int(exactly:)`. | Crash resistance. | S | **now** |
| B7 | Ad-hoc signature; runs from `.build/release`; no bundle, version or `--version`. The Accessibility grant is tied either to the terminal (every child inherits it) or to the binary's hash (lost on every rebuild). Build volume ignores ownership and is unencrypted. | A rebuild silently revokes Accessibility or swaps the running binary; anything launched from the terminal has Accessibility. | Minimal `Tessera.app` (`LSUIElement`, bundle id, version+SHA), signed with a stable identity (self-signed keychain cert now, Developer ID later), launched by the LaunchAgent so it is its own TCC principal; `scripts/install.sh` with rollback; remove the terminal's grant; build on an owner-enforced encrypted volume. | Largest real-world risk; precondition for B4 and distribution. | M | **now** |
| B8 | Private APIs: `_AXUIElementGetWindow` bound at link time in three places (dyld abort if removed); SkyLight via `unsafeBitCast` with assumed signatures. | An OS update makes the app fail to launch or behave undefined. | One `dlsym` shim with a CGWindowList frame+pid fallback; SkyLight self-test at start (active Space ∈ managed Spaces) and disable if inconsistent. | Survives OS updates. | S–M | **next** |

### C. Reconciliation correctness — P1

| ID | Finding | Failure | Solution | Impact | Effort | Verdict |
|---|---|---|---|---|---|---|
| C1 | Facts learned from failed or clamped writes: AX errors discarded (`AXApplication.swift:232-246`); `learn()` runs on any read-back; any shrink > 24 pt becomes `maxSize` (`Engine.swift:685-713`). | A busy app (>350 ms twice) or a frame pushed past the display edge (macOS clamps 2000→540, ADR 0002) teaches a wrong `maxSize`: the window can never grow again. | Return per-call AX errors; learn nothing on error/timeout; never learn `maxSize` when the target exceeds the display or the result touches its edge; require a settled second read; invalidate after 2 contradictions (plan §4.3). | Windows stop getting stuck small/large. | M | **now** |
| C2 | Learn/write loop unbounded: each different candidate resets `attempts` and re-renders (`Engine.swift:723-726`); the drift budget does not cover it. | A window whose refusals alternate A/B flickers forever at 20–40 ms per write. | Plan §4.4 per-window pass budget (≤ 3 per epoch), then observed frame as hard constraint with backoff 60 s → 5 min; share with the drift budget. | No flicker or CPU storms. | S–M | **now** |
| C3 | No second-monitor guard: `Displays.main()` = `screens.first`; hide corner = primary's bottom-right (`Displays.swift:16`; `Engine.swift:754`). | Plugging a display, Sidecar or AirPlay pulls that display's windows onto the primary; parked windows appear on a display to the right/below. | Until phase 3: manage only windows centred on the primary; pick a corner not touching another display; menu warning. | Plugging a display does not wreck the layout. | S | **now** |
| C4 | Edge clamp learns from any single window and accumulates without cap (`EdgeClamp.swift:25-33`); `didChangeScreenParameters` does not reset it. | A grid-snapping terminal's 1–3 pt shortfall is blamed on the screen: the area shrinks for everyone. | Require two different pids to agree; cap at 3 pt; route screen changes through `refreshScreen()`. | Exact tiling. | S | **next** |
| C5 | Late completions recreate windows; `release` bypasses `forgetWindow`; `rejected`, `driftBudget`, `factCandidates` never pruned (`Engine.swift:190-194, 327`). | An app quits during a scan: its windows reappear as holes for ~2 s; maps grow over days. | Per-pid generation guard in `absorb`; `release` → `forgetWindow`; prune all maps there. | No ghost holes; bounded memory. | S | **now** |
| C6 | No runtime check that windows landed; after 2 attempts the target is abandoned for good; hidden windows rewritten every render if macOS nudges the corner. | After a short hang a window stays misplaced until the layout changes. | I9 check on the audit tick for settled windows, 1 retry with backoff; treat "near the corner" as hidden. | Self-correcting layout. | M | **next** |
| C7 | Observer thread makes blocking AX calls under the 1.5 s timeout on every window created, in `absorb` and every `discoverMissed` (`AXObserverHub.swift:100-115`). | One hung app delays close/focus notifications for every app by 1.5 s per call. | Enumerate on the app's queue and hand elements to the hub; 0.35 s timeout on the hub's app element; back off from unresponsive apps. | Snappy under hangs. | M | **next** |
| C8 | `pendingFocus` never expires (`Engine.swift:508, 645`). | `focus --window-id` on a hidden/minimised window fires minutes later and steals focus. | Expire after one render or 500 ms; clear on system focus change. | No surprise focus jumps. | S | **now** |

### D. Model gaps the user meets daily — P1

| ID | Finding | Failure | Solution | Impact | Effort | Verdict |
|---|---|---|---|---|---|---|
| D1 | Directional focus does nothing in monocle and accordion: `Navigation` needs distance ≥ 0, but their tiles coincide/overlap (`Navigation.swift:16-20`). Untested. | Ctrl+Opt+H/J/K/L do nothing in the two layouts the owner uses most. | Tree-order previous/next in overlapping containers (AeroSpace behaviour); geometry elsewhere; tests. | Keyboard-usable layouts. | S | **now** |
| D2 | User's float/tile choice not kept: `mode = wasFloating ∨ prefersFloating` (`Reducer.swift:53-65`). | A tiled dialog re-floats on the next rescan; a floated window comes back tiled after minimise/Cmd-H. | `userOverride` in `WindowRecord`; `autoFloated` as derived flag (plan I10). | Respects the user. | S | **now** |
| D3 | Zoomed window covers floating windows (`Renderer.swift:61`). | A dialog opened in Tessera full screen is hidden behind it. | Keep floating windows in front. | Dialogs stay visible. | S | **now** |
| D4 | Overflow/accordion frames can exceed the usable area; autoFloated, `stack`/`float-largest`/`allow` and the 4-strip cap (plan §4.2) not implemented (`Solver.swift:195-225`). Silent reflow. | Windows partly off screen (feeds C1); two wide apps stack with no explanation. | Implement autoFloated + policies; one OSD per workspace ("No caben lado a lado: apiladas"). | Clean, explained overflow. | M | **next** |
| D5 | "All desktops" windows tiled on every Space and moved between trees on each switch; scratchpad absent. | Layout reflows on every Space switch. | Float windows that are on more than one Space (plan I10). | Stable layouts. | S | **next** |
| D6 | Facts keyed by window id, never persisted, no TTL/invalidation. | Everything relearned per restart; stale minimums after font changes. | Plan §4.3 key (bundle, version, subrole, scale), 30-day TTL, invalidation. | Fewer re-layouts. | M | **later** |

### E. Product, UX and accessibility — P1/P2

| ID | Finding | Failure | Solution | Impact | Effort | Verdict |
|---|---|---|---|---|---|---|
| E1 | **Menu blocker**: in native mode "Espacio N" rows send `.workspace(N)`, which jumps to macOS desktop N (`StatusMenu.swift:87-89`; `Engine.swift:529-537`). Menu rebuilt only when the title changes → stale counts. No checkmark on the active layout, no shortcut glyphs, accessibility label fixed "Tessera". | Clicking the ticked "Espacio 1" from desktop 3 lands on desktop 1; wrong counts; VoiceOver never hears the desktop. | Native mode lists desktops ("Escritorio 1…N", current ticked); build lazily in `menuNeedsUpdate`; `state` + key equivalents; `accessibilityValue` = "Escritorio 3"; SF Symbol template image. | Removes the only UX blocker. | S | **now** |
| E2 | No feedback channel: refused hotkeys, unresponsive apps, frames accepted after 2 refusals, edge clamp, missing desktop, `move-node-to-workspace` → stderr or a beep. | The user sees nothing, or a beep with no explanation. | Non-activating OSD (NSPanel, ~1.5 s, respects Reduce Transparency/Motion) + `announcementRequested` for VoiceOver; "Actividad reciente" submenu. Wire the six silent sites. First 3 beeps of move-node explain: "Arrastra la ventana y pulsa ⌃2". | Every silent failure becomes guidance. | M | **now** |
| E3 | Permission lifecycle: `AXIsProcessTrusted()` once, English error, exit; no prompt; revocation unnoticed. | Cryptic terminal error; after revocation hotkeys fire but nothing moves; emulated-hidden windows stay parked. | `AXIsProcessTrustedWithOptions(prompt)`; "Sin permiso" icon state with "Abrir Privacidad › Accesibilidad…"; re-check on audit tick; auto-resume and restore (plan §3). | Trust and recovery. | S–M | **now** |
| E4 | No Pause; the menu only has Quit. Restart requires a terminal. | Screen sharing or a manual layout means quit + terminal restart. | "Pausar Tessera" toggle + ⌃⌥P; outline icon; unregister all hotkeys but resume; "Reunir todas las ventanas". | Daily usability. | S | **now** |
| E5 | Keymap: every chord is Control+Option = VoiceOver's modifier; ⌃⌥Space is macOS's "select next input source"; refusals silent; keymap undocumented anywhere (README says nothing manages windows). | VoiceOver users lose navigation or tiling; ES/EN users lose input switching; everyone learns keys from the source code. | Watch `isVoiceOverEnabled` (KVO) → switch live to Control+Option+Command with announcement; move toggle-floating to ⌃⌥⇧Space; check keymap against `symbolichotkeys` at start and report clashes; "Atajos de teclado…" cheatsheet from `DefaultKeymap` + hold-⌃⌥ HUD; `tessera keys`; README user section. | Discoverable, safe, accessible. | S–M | **now** |
| E6 | Native desktop navigation: `previousDesktop` only tracks Tessera's own jumps; arrow fallback counts desktop steps but crosses full-screen Spaces (owner has one); missing desktop only logged. | ⌃⌥Tab wrong after a trackpad swipe; slow jumps landing on the full-screen app; ⌃⌥4 with 3 desktops does nothing. | Track previous desktop in `spaceMayHaveChanged`; count steps over the full Space order; OSD + menu link to Keyboard Shortcuts when direct jump is off; OSD "Solo hay 3 escritorios" + "Abrir Mission Control". | Predictable navigation. | S | **now** |
| E7 | No preflight: AeroSpace excluded but not detected as a running competitor; no Stage Manager / separate-Spaces / edge-tiling checks (plan §10.2). `EnvironmentProbe` already detects them. | Two window managers fight; windows twitch. | Preflight at start with an alert ("AeroSpace está en marcha — ¿Salir?"); refuse to start with another tiler running. | No window fights. | S | **now** |
| E8 | Drag: no highlight while dragging, no drop zones; macOS edge tiling ignored. | Swap found by accident; drop near the top edge triggers macOS "fill" and fights Tessera. | Translucent highlight on the target tile while `draggedByUser` non-empty; startup warning when edge tiling is on. | Discoverable mouse model. | M | **next** |
| E9 | No configuration: `excludedBundleIDs` hard-coded; every regular app managed; keymap fixed. | Cannot float Zoom/System Settings, cannot rebind keys. | Minimal read-only `~/.config/tessera/tessera.local.toml` (exclude, float, gaps, keymap overrides) — plan D4's overlay path; GUI later. | Fit for other users. | M | **next** |
| E10 | Localisation and copy: Spanish menu literals, English CLI/errors/logs, "Espacio" vs "Escritorio", "Maximizado (monocle)". | Two words for one thing; jargon. | String Catalog (es, en) + glossary: Escritorio = macOS desktop; "Grupo" for emulated workspaces only. | Coherent product language. | S–M | **next** |
| E11 | No first-run preview/revert; startup retiles instantly. | The user's arrangement is lost on first run. | Snapshot frames at start; "Revertir a la disposición original" for 10 minutes. | Safe first contact. | S | **next** |
| E12 | `com.apple.symbolichotkeys` was changed by the agent with consent; backup exists but no restore path; product must never write it. | Control-1…9 taken from every app with nothing explaining why. | `scripts/restore-hotkeys.sh` (`defaults import` + `activateSettings -u`) documented in ADR 0003; onboarding opens Keyboard Shortcuts instead of writing. | Reversibility. | S | **now** |

### F. Quality, CI, operations — P1/P2

| ID | Finding | Failure | Solution | Impact | Effort | Verdict |
|---|---|---|---|---|---|---|
| F1 | CI has never run: GitHub-syntax workflow, Forgejo Actions off, no local gate. | Regressions land unnoticed. | `scripts/gate.sh` (build, test, Core has no Foundation/AppKit import, no titles in logs/fixtures) + pre-push hook now; self-hosted forgejo-runner on the Mac Studio (`macos-arm64`, separate user) next. | A gate that runs. | S / M | **now / next** |
| F2 | Engine untested; `TesseraFakes` is a 2-line placeholder; no ports; the riskiest code (A1, C1, C2, C4, C5) has 0 % coverage. | Regressions reach the owner's desktop. | `WindowServerPort`, `AccessibilityPort`, `SpacePort`, `Clock`; `FakeWindowServer` with the ADR 0002 clamp and fixture-001; `TesseraEngineTests`; regression tests for A1–C8. | Confidence to refactor. | L | **next (start now)** |
| F3 | Invariants I5–I18 undefined in the repo ("como v3.1"); ★ invariants I7, I9, I10, I11 not asserted; no model-based reducer test (plan: 1 M/night). | The DoD cannot be evaluated; tree/focus corruption after unusual event orders goes unnoticed. | `docs/invariants.md`; `Invariants.check(world, render)` in Core, used by tests and by the engine in debug builds; seeded random event sequences checking invariants at every step. | Measurable DoD. | M | **now** |
| F4 | Logging: stderr, no timestamps/levels/rotation/version line; repeated lines unthrottled; `--verbose` logs pointer coordinates. | Crashes cannot be ordered in time or tied to a build. | `os.Logger` (subsystem `dev.rrios.tessera`, categories engine/ax/ipc/journal, `privacy: .private` for ids/coordinates); version/SHA/pid at start and exit reason; rate-limit; `OSSignposter` render→apply→settle; `uptime`, `version`, `lastError` in `debug stats`. | Diagnosable. | S | **now** |
| F5 | Live tests: fixed sleeps, single green run, untriaged FAILs in old outputs, results gitignored, helper tools compiled by hand into `.build/`, `real.py` runs in the owner's session, return-to-Space unverified. | Flaky signal, lost history, fresh clone breaks scripts, owner left on the wrong desktop or with AeroSpace off. | Poll-until-deadline; N=20; append `spikes/results/*.jsonl`; classify infra vs product (§12); `tessera-labtools` target; assert return to the starting Space; trap signals; move to `tessera-lab` (S11). | Trustworthy signal. | M | **next** |
| F6 | `World` never persisted; journal is JSON, not the plan's WAL. | A restart loses the layout. | Debounced `World` snapshot + `lastJournalSeq`; surface journal write failures. | Continuity. | M | **next** |
| F7 | Bench covers only the core; hotkey→setFrame and apply-10 gates unautomated. | §11 gates unverified. | Bench on the self-hosted Mac against stored baselines; fail on > 20 % regression or the absolute budget. | Perf gate. | S | **next** |
| F8 | Docs drift: README stale; no runbook; `.gitignore` excludes `spikes/**/output/` while CLAUDE.md says raw data is committed; S12 has no README. | Wrong operational steps. | `docs/RUNBOOK.md` (start/stop/restart/recover stranded windows/collect logs); fix README; align `.gitignore`. | Clarity. | S | **now** |
| F9 | Maintainability: `Engine.swift` 843 lines, ~25 mutable fields, >12 unnamed timing constants; dead code (`lock`, unused silgen, stale doc, `carrying` always false); `_AXUIElementGetWindow` declared three times; `StatusMenu.commands` grows on every rebuild. | Every new feature adds risk. | Extract `Reconciler`, `Hider`+`Journal`, `Discovery`; `Timing` enum; remove dead code. | Faster, safer change. | M | **next** |
| F10 | Hygiene: test flags (`--only-pid`, `--tile-all`, …) in the production CLI; `DummyWindowApp` accept loop spins; CI actions pinned by tag; fixture-001 carries display serial/UUID/model. | Low risk; fingerprint if the repo is published. | `#if DEBUG` for test flags; dev-only product; pin by SHA + `permissions: contents: read`; `doctor` redacts identifiers by default. | Hygiene. | S | **later** |
| F11 | `AXEnhancedUserInterface` toggled without journaling; plan §8 restore at start not implemented. | A crash between the two writes leaves an app's assistive tree degraded. | Journal toggled pids; restore at start. | Accessibility safety. | S | **next** |

## 3. What is genuinely solid

- Stdlib-only core: integer geometry, ppm weights with largest remainder and water-filled floor,
  idempotent normalisation, a solver that partitions exactly (property-tested over 20,000 trees).
- Echo suppression of Tessera's own writes is correct (per-app FIFO queues, `inFlight`, `lastWrite`).
- Every `MainActor.assumeIsolated` runs on a main-queue callback; `windowIDs` is confined to the
  observer thread.
- Liveness by tracked CGWindowID; window titles are never read anywhere (enforced in code and in
  `CLAUDE.md`); SkyLight read-only via `dlsym` with fallback; no keyboard event tap; no
  third-party dependencies.
- Journal written before hiding; SIGINT/SIGTERM/Quit restore; idle CPU ≈ 0 %; closed window's
  space back in ~36 ms; ADRs backed by measurements.

## 4. Remediation plan

Ordered by benefit/effort. Days are one engineer plus assistant.

| Wave | Items | Days | Outcome |
|---|---|---|---|
| **1 · Nothing gets lost, nothing crashes** | A1, A2, B1, B2, B3, B5, B6, C5, C8, E12 | 3 | No stranded windows; no crash or keystroke flood from local input; tests cannot hurt the owner's instance. |
| **2 · A real app** | B7, A3, E3, E4, F4 | 4 | Signed `Tessera.app` + LaunchAgent (TCC survives rebuilds, auto-restart, safe mode), permission state, pause, timestamped logs with version. |
| **3 · Daily correctness** | D1, D2, D3, C1, C2, C3, C4, E1, E6, E7 | 5 | Focus works in every layout; user choices kept; no stuck sizes or flicker loops; second monitor safe; menu correct; native navigation right; no fights with other tilers. |
| **4 · Feedback and discovery** | E2, E5, F8 | 4 | OSD + VoiceOver channel wired to every silent failure; VoiceOver-safe keymap; cheatsheet/HUD; runbook and README. |
| **5 · Verification** | F1, F3, F2 (start), F5 | 8 | Local gate + runner; invariant catalogue and checker; model-based reducer test; fakes and engine tests; live suite with history. |
| **6 · Next** | A4, B4, B8, C6, C7, D4, D5, E8, E9, E10, E11, F6, F7, F9, F11 | ~15 | Before the week-22 checkpoint. |
| **Later** | D6, F10 | — | — |

**Definition of "ready for someone else"** (target grade ≥ 7 overall): waves 1–5 done, every ★
invariant asserted in fakes and checked at runtime, C23 (kill -9 → all windows restored ≤ 7 s)
passing 20/20, zero P0/P1 open.
