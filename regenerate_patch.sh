#!/usr/bin/env bash
#
# regenerate_patch.sh — Recompute ethernet-over-usb.patch from scratch against
# whatever bitaxeorg/ESP-Miner master and mutatrum/ESP-Miner's usb-ethernet
# branch look like *right now*.
#
# Use this when:
#   - ethernet-over-usb.patch no longer applies cleanly (upstream master has
#     drifted further), or
#   - mutatrum has pushed new commits to the usb-ethernet branch and you want
#     to pick them up.
#
# What it does NOT do: resolve conflicts for you. It regenerates the patch
# using the same "diff against the fork's last sync point with master" trick
# that produced the original patch, then tries a 3-way apply. If master has
# changed the touched files in ways that don't textually align (renamed
# functions, refactored files, etc. — this happened once already, when
# stratum_task.c was split into stratum_v1_task.c/stratum_v2_task.c), you
# will get conflict markers and need to resolve them by hand, the same way
# the original patch was produced. Search the touched files for the old
# WiFi-specific connectivity check being replaced by a link-agnostic one
# (grep for wifi_is_connected / is_wifi_connected) as a good starting point,
# since that's the pattern that broke last time.
#
set -euo pipefail

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$WORKDIR/ESP-Miner"
ETH_REMOTE="https://github.com/mutatrum/ESP-Miner.git"
ETH_BRANCH="usb-ethernet"
OUT_PATCH="$WORKDIR/ethernet-over-usb.patch"

if [[ ! -d "$REPO_DIR" ]]; then
    git clone --recursive https://github.com/bitaxeorg/ESP-Miner.git "$REPO_DIR"
fi

cd "$REPO_DIR"
git fetch origin master
git remote add ethfork "$ETH_REMOTE" 2>/dev/null || git remote set-url ethfork "$ETH_REMOTE"
git fetch ethfork "$ETH_BRANCH"

MERGE_BASE="$(git merge-base origin/master "ethfork/$ETH_BRANCH")"
echo "Merge base of master and mutatrum/$ETH_BRANCH: $MERGE_BASE"
echo "  ($(git log -1 --oneline "$MERGE_BASE"))"
echo

# Exclude main/tasks/stratum_task.c: this file was split into
# stratum_v1_task.c / stratum_v2_task.c on master after the fork's last
# sync (Stratum V2 support, PR #1553), and the fork's one small hunk there
# (swapping a WiFi-specific connectivity check for a link-agnostic one) is
# obsolete against the new file layout. If your merge base has moved past
# that split already, this exclusion is a no-op.
git diff "$MERGE_BASE" "ethfork/$ETH_BRANCH" -- . ':!main/tasks/stratum_task.c' > "$OUT_PATCH"

echo "Wrote $(wc -l < "$OUT_PATCH") lines to $OUT_PATCH"
echo

echo "Testing whether it applies cleanly to current master..."
git checkout --quiet -B ethernet-over-usb-regen origin/master
if git apply --check "$OUT_PATCH" 2>/dev/null; then
    echo "CLEAN APPLY — ethernet-over-usb.patch is up to date and ready to use."
else
    echo "Does not apply cleanly. Attempting 3-way merge to show you what's left:"
    git apply --3way --whitespace=fix "$OUT_PATCH" || true
    CONFLICTED=$(git diff --name-only --diff-filter=U || true)
    if [[ -n "$CONFLICTED" ]]; then
        echo
        echo "Conflicted files (need manual resolution):"
        echo "$CONFLICTED" | sed 's/^/  - /'
        echo
        echo "Also double check for a connectivity-check swap, e.g.:"
        echo "  grep -rn 'wifi_is_connected\\|is_wifi_connected' main/ components/"
        echo "Any call site that gates stratum reconnect/heartbeat logic on WiFi-only"
        echo "status should use GLOBAL_STATE->SYSTEM_MODULE.is_connected instead, so"
        echo "it also works over USB ethernet."
        echo
        echo "After resolving by hand, regenerate the patch file with:"
        echo "  git diff origin/master HEAD > \"$OUT_PATCH\""
    fi
fi
