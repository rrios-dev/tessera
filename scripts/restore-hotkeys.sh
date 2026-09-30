#!/bin/zsh
# Puts macOS's keyboard shortcuts (com.apple.symbolichotkeys) back to how they were before
# "Switch to Desktop N" was turned on for Tessera on 2026-09-25 (ADR 0003, audit E12).
#
# Tessera itself never writes these preferences; this undoes the one change made by hand, with
# the owner's consent, during spike S12. A backup of the current state is kept first.
#
# usage: scripts/restore-hotkeys.sh [backup.plist]
set -euo pipefail
here=${0:A:h}
source_plist=${1:-$here/../spikes/S12-native-spaces/symbolichotkeys-before.plist}
[[ -f $source_plist ]] || { echo "no backup at $source_plist" >&2; exit 1; }

stamp=$(date +%Y%m%d-%H%M%S)
current=${TMPDIR:-/tmp}/symbolichotkeys-$stamp.plist
defaults export com.apple.symbolichotkeys "$current"
echo "current shortcuts saved to $current"

defaults import com.apple.symbolichotkeys "$source_plist"
# Makes the change take effect without logging out.
/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
echo "restored from $source_plist"
