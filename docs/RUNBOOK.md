# Runbook

Operating Tessera on the owner's Mac. Commands assume the repository root.

## Start, stop, restart

| Goal | Command |
|---|---|
| Build | `swift build -c release` |
| Start by hand (foreground) | `.build/release/tessera run` |
| Start by hand (background, log file) | `nohup .build/release/tessera run >/dev/null 2>&1 &` |
| Stop, restoring every hidden window | menu › "Salir de Tessera y restaurar ventanas", or `kill -TERM <pid>` |
| Pause without quitting | ⌃⌥P, menu › "Pausar Tessera", or `tessera pause` / `tessera resume` |
| Is it running, which build, what state? | `tessera debug stats` (version, status, uptime, last error, counters) |
| Check every invariant now | `tessera debug check` |
| Recent notices | `tessera debug activity` |
| Shortcuts | `tessera keys` (or hold ⌃⌥ for a moment) |

## Run as a service (login item, restart after a crash)

```bash
scripts/install.sh                 # builds release, installs ~/Applications/Tessera.app, installs the LaunchAgent
tessera service status
tessera service restart
tessera service uninstall
```

The agent (`~/Library/LaunchAgents/dev.rrios.tessera.plist`) has `KeepAlive = {SuccessfulExit =
false, Crashed = true}` and `ThrottleInterval = 5`: launchd brings Tessera back after a crash,
never after Quit. Three unclean starts within five minutes start it in **safe mode** (every
window restored, nothing moves) until "Reintentar".

**Accessibility.** Signed with a Developer ID, the permission follows the signature: grant it
once and it survives every later install. Signed ad hoc (no identity in the keychain), macOS ties
it to the binary's hash and it must be re-granted after each install. Either way Tessera waits in
"Sin permiso" and resumes by itself the moment the permission is there.

## Signing (Developer ID, audit B7)

One-time setup; the private key never leaves the Mac and never enters the repository.

1. The request is generated locally: `~/Library/Application Support/Tessera-signing/`
   holds `developer-id.key` (0600) and `DeveloperID.certSigningRequest`.
2. developer.apple.com › Certificates › + › **Developer ID Application** (G2 Sub-CA) › upload the
   request › download `developerID_application.cer`.
3. Apple's intermediate: `curl -fsSLo ~/Downloads/DeveloperIDG2CA.cer https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer`
4. `scripts/import-developer-id.sh ~/Downloads/developerID_application.cer ~/Downloads/DeveloperIDG2CA.cer`
5. Notarization credentials, once (asks for an app-specific password from account.apple.com):
   `xcrun notarytool store-credentials tessera-notary --apple-id <email> --team-id <TEAMID>`
6. `scripts/install.sh` signs with hardened runtime and a timestamp, notarizes, staples and
   installs. A signed engine accepts commands only from programs signed by the same team, so the
   CLI to use is `~/.local/bin/tessera` (the installed, signed binary); queries stay open.

## Recover windows

| Symptom | Do |
|---|---|
| A window is parked in the bottom-right corner | Menu › "Reunir todas las ventanas", or `tessera gather`. |
| Tessera was killed hard (`kill -9`, crash) | Start it again: the rescue sweep restores every journaled window (`journal.json`). Windows on another desktop come back when you visit it. |
| Tessera will not start again | `tessera run` prints why. "another Tessera engine is running" → `pgrep -fl 'tessera run'`. |
| The first arrangement was unwelcome | Menu › "Revertir a la disposición original" (first 10 minutes), or `tessera revert-layout`. |
| Hotkeys do nothing | `tessera debug stats` → status. "paused (AeroSpace running)": quit the other tiler. "waiting for the Accessibility permission": see above. |
| Control-1…9 should go back to how macOS had them | `scripts/restore-hotkeys.sh` (ADR 0003). |

## Files

`~/Library/Application Support/Tessera/` (0700; every file 0600; `TESSERA_HOME` or
`--state-dir` selects another directory, which also gives the engine its own socket):

| File | What |
|---|---|
| `journal.json` | Original frames of hidden windows; entries leave only on a confirmed restore. |
| `world.json` | The trees, saved two seconds after each change; restored on the next start of the same boot. |
| `facts.json` | Learned minimums/maximums per app, version, window kind and scale; 30-day lifetime. |
| `edge-clamp.json` | The Dock clamp per screen arrangement. |
| `starts.json` | Crash-loop guard. |
| `tessera.log`, `tessera.log.1` | The log, rotated at 5 MB. Also in the unified log: `log stream --predicate 'subsystem == "dev.rrios.tessera"'`. |
| `engine.lock` | One engine per directory. |

A corrupt file is moved aside as `*.corrupt-<time>.json` and reported, never silently emptied.

## Configuration

`~/.config/tessera/tessera.local.toml` (example in `docs/configuration.md`). Reload with menu ›
"Recargar configuración" or `tessera reload-config`; errors are reported and the rest applies.

## Collect logs for a bug

```bash
tessera debug stats > /tmp/tessera-stats.txt
tessera debug state > /tmp/tessera-state.json      # window ids only, never titles
cp ~/Library/Application\ Support/Tessera/tessera.log /tmp/
tessera doctor --output /tmp/tessera-doctor.json   # identifiers redacted unless --raw
```

## Before pushing

`scripts/install-hooks.sh` once; the pre-push hook runs `scripts/gate.sh` (build, tests, core
import rule, no titles, environment reads, performance budgets against `bench/baseline.json`).

## CI runner

Forgejo Actions needs a self-hosted macOS runner (`.forgejo/workflows/ci.yml`, label
`macos-arm64`). To install it on the Mac Studio: create a standard user without the
Accessibility permission, download `forgejo-runner` for darwin-arm64 from
code.forgejo.org, `forgejo-runner register --labels macos-arm64:host`, and run it as that
user's LaunchAgent. Until then the pre-push gate is the gate.

## Live tests

```bash
swift build
python3 spikes/S1-single-monitor/live.py --runs 3         # sandbox, own state directory
python3 spikes/S1-single-monitor/wait-and-run.py --runs 5 # waits for an idle desktop, stops and restarts the owner's engine
```

Results accumulate in `spikes/results/*.jsonl`. Failures are classified *infra* (the harness
could not set up) or *product* (an invariant broke).

## Publishing a version (github.com/rrios-dev/tessera)

The public repository carries a clean history: the `public` branch here, one commit per release,
never the private history (which kept machine identifiers in old fixtures). Forgejo keeps both.

```bash
git switch public && git checkout main -- . && git add -A
git commit -m "Tessera <version> — <summary>"          # after bumping BuildInfo.version on main
git push github public:main && git switch main
git switch public && scripts/release.sh && git switch main   # signed, notarized, universal zip + dmg in dist/
gh release create v<version> dist/Tessera.dmg dist/Tessera.dmg.sha256 \
  dist/Tessera-<version>.zip dist/Tessera-<version>.zip.sha256 \
  --repo rrios-dev/tessera --target main --title "Tessera <version>" --notes-file <notes>
```

`Tessera.dmg` keeps no version in its name so that
`/releases/latest/download/Tessera.dmg` (linked from the README and rrios.dev) always serves the
newest. Its window is `assets/dmg` (`make-background.sh` after editing `background.svg`), laid out
by `scripts/dmg-settings.py`; `scripts/make-dmg.sh` wraps an already notarized app on its own.

Before each publish: `git grep -nE "UUID \`|/Users/|serial\" : [1-9]" public` must find nothing
machine-specific, and fixtures are captured with `tessera doctor` (redacted by default).
