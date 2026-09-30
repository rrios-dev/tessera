#!/bin/zsh
# The local quality gate (audit F1): what CI runs, runnable before every push.
#   build, the full test suite, the core's import rule, no window titles anywhere, the
#   performance budgets, and the maturity checks of the repository itself.
set -euo pipefail
cd ${0:A:h}/..
step() { print -P "%B▸ $1%b" }
fail() { print -P "%F{red}✘ $1%f" >&2; exit 1 }

step "build (debug and release)"
swift build
swift build -c release --product tessera

step "tests"
swift test 2>&1 | tail -3 | tee /dev/stderr | grep -q "passed after" || fail "tests failed"

step "TesseraCore imports the standard library only"
if grep -rnE '^\s*(public |internal |@testable )?import +(Foundation|AppKit|Cocoa|CoreGraphics|ApplicationServices)' Sources/TesseraCore; then
  fail "TesseraCore must not import platform frameworks"
fi

step "no window titles read or logged"
if grep -rnE 'kAXTitleAttribute|kCGWindowName|"AXTitle"' Sources; then
  fail "window titles must never be read"
fi

step "no process.env-style environment reads outside configuration"
# Environment variables are read only by the CLI entry point, state paths, localisation and IPC.
allowed='Sources/tessera/|Sources/tessera-bench/|Sources/tessera-labtools/|Sources/DummyWindowApp/|StatePaths.swift|L10n.swift|LineSocket.swift|BuildInfo.swift|Service.swift|EnvironmentProbe.swift'
if grep -rn 'ProcessInfo.processInfo.environment' Sources | grep -vE "$allowed"; then
  fail "read environment variables only at the documented entry points"
fi

step "performance budgets (plan §11) and baselines"
swift run -c release tessera-bench --check

print -P "%F{green}✔ gate passed%f"
