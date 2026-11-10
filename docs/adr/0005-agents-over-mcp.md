# 0005 — Agents use Tessera over MCP

Status: accepted (2026-10-14, owner)

## Context

The owner works in Claude Code daily and wants their Mac apps — Quill, Ámbar and Tessera —
usable from agents (Claude Code, Codex): read the layout, arrange windows. The cross-app
design lives in the Forge monorepo, `docs/initiatives/mac-apps-mcp/DESIGN.md`; this record
is Tessera's part. macOS offers no bridge from apps to MCP clients (checked in the macOS 27
SDK: App Intents reach Siri and Shortcuts only).

## Options

1. **A separate MCP executable** next to `tessera`. A second binary to sign, notarise and
   install, and a second client the engine would have to trust.
2. **A subcommand of the same binary, `tessera mcp`** (chosen). The binary is already the
   CLI the engine trusts for commands (team signature, audit B4), so the MCP server needs no
   new trust path: it sends the same `IPCRequest`s over the same socket, with the same rate
   limits.
3. **An HTTP server in the engine.** A listening port, a token, and agent traffic inside
   the process that moves windows. Rejected.

## Decision

- `tessera mcp` serves MCP over stdio with MCPKit (`rrios-dev/mcpkit`, the owner's own
  package, MIT, Foundation only) — **the first dependency outside this repository**, accepted
  because it is the owner's and shared with Quill and Ámbar.
- **Off by default**: `[agents] enabled = true` in `tessera.local.toml` turns it on, read on
  every call. With it off every tool answers how to turn it on.
- **Tools**: `get_layout` (desktops, workspaces, windows by id, app and frame), and the
  engine's own commands — focus, move, move to workspace, switch workspace, layout, resize,
  full size, balance, and `retile` / `pause` / `resume` / `revert-layout`. Commands that take
  a `window_id` focus it first, then act, exactly as a user would.
- **No titles.** Windows are named by their app (`kCGWindowOwnerName`, bundle identifier from
  the pid), never by title; `scripts/gate.sh`'s title rule still holds.
- **Access log**: `agent-access.log` in the state directory, 0600, tool names and clients
  only, trimmed to the last few hundred lines.
- The MCP server never starts the engine: if it is not running, the tool says so.

## Evidence

- `Tests/TesseraMCPTests`: the layout described from a recorded state (app names, frames,
  focus, floating, full-screen Spaces), the requests each command sends (focus first, resize
  signs), refusals and a stopped engine reaching the agent as text, annotations.
- `Tests/TesseraConfigTests`: `[agents] enabled` parsed, off by default, typed.
- `tessera mcp` answers `initialize` and lists its eleven tools over stdio.
- The owner's run with Claude Code is the slice's validation point (DESIGN.md §9, S3).

## Live audit (2026-10-14)

`spikes/mcp-audit/audit.py` drives every tool through `tessera mcp` against the owner's
engine and checks each effect against `tessera debug state` and the window server: 70 checks,
all passing after it found and fixed four defects —

1. A command for a window that does not exist answered "Done" (the engine ignores unknown
   ids): the MCP now checks the layout first.
2. In native desktops mode, `workspace 2` with one desktop and any `move-node-to-workspace`
   showed an on-screen notice but answered IPC callers "ok": the engine now returns the
   reason, and the notice still shows.
3. Refusals read "refused: refused:" with doubled stops, and engine actions did not say the
   state Tessera ends in (retile resumes a pause, revert-layout pauses): fixed.
4. An agent session that outlives Tessera updates loses commands: once the binary it was
   started from is replaced, macOS reports "the code on disk does not match what is running"
   and the engine (rightly) refuses it. The server now recognises that case and tells the
   agent to reconnect. Reading keeps working.

Also measured: TextEdit windows named `SECRETO-n.txt` never appear in any output or in the
access log; an unsigned build may read but not command; rate limits reach the agent as text.
