#!/bin/zsh
# Points git at the versioned hooks (pre-push runs scripts/gate.sh).
set -euo pipefail
cd ${0:A:h}/..
git config core.hooksPath .githooks
echo "git hooks: .githooks (pre-push runs scripts/gate.sh)"
