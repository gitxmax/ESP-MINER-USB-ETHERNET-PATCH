#!/usr/bin/env bash
#
# patch_and_build.sh — Apply the Ethernet-over-USB patch to a fresh checkout
# of bitaxeorg/ESP-Miner (master) and build it, producing esp-miner.bin,
# www.bin, and a flashable merged image, for a Bitaxe Gamma (board 601).
#
# Usage:
#   ./patch_and_build.sh                 # clone, patch, build (Docker)
#   ./patch_and_build.sh --native         # build with a locally installed
#                                         # ESP-IDF instead of Docker
#   ./patch_and_build.sh --skip-build     # only clone + patch, no build
#   ./patch_and_build.sh --config 601     # board config (default: 601 = Gamma)
#
# Requires: git, and either Docker, or a sourced ESP-IDF (v5.5+) environment
# for --native. bitaxetool (pip install bitaxetool) if you want this script
# to also flash the result.
#
set -euo pipefail

REPO_URL="https://github.com/bitaxeorg/ESP-Miner.git"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$WORKDIR/ESP-Miner"
PATCH_FILE="$WORKDIR/ethernet-over-usb.patch"
OUT_DIR="$WORKDIR/output"
BUILD_MODE="docker"
DO_BUILD=1
BOARD_CONFIG="601"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --native) BUILD_MODE="native"; shift ;;
        --skip-build) DO_BUILD=0; shift ;;
        --config) BOARD_CONFIG="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ ! -f "$PATCH_FILE" ]]; then
    echo "ERROR: $PATCH_FILE not found. Keep it next to this script." >&2
    exit 1
fi

echo "=== 1/5: Cloning bitaxeorg/ESP-Miner (master) ==="
if [[ -d "$REPO_DIR" ]]; then
    echo "  $REPO_DIR already exists — fetching latest master instead of re-cloning."
    git -C "$REPO_DIR" fetch origin master
    git -C "$REPO_DIR" checkout -B ethernet-over-usb origin/master
else
    git clone --recursive "$REPO_URL" "$REPO_DIR"
    git -C "$REPO_DIR" checkout -B ethernet-over-usb origin/master
fi
git -C "$REPO_DIR" submodule update --init --recursive

echo
echo "=== 2/5: Applying the Ethernet-over-USB patch ==="
cd "$REPO_DIR"
git config user.email >/dev/null 2>&1 || git config user.email "patch-builder@local"
git config user.name >/dev/null 2>&1 || git config user.name "Patch Builder"
if git apply --check "$PATCH_FILE" 2>/dev/null; then
    git apply "$PATCH_FILE"
    git add -A
    git commit --quiet -m "Apply ethernet-over-usb.patch"
    echo "  Patch applied and committed cleanly (keeps 'git describe' free of -dirty)."
else
    echo "  Patch does not apply cleanly against current master (upstream has"
    echo "  likely moved on since this patch was generated). Attempting a"
    echo "  3-way merge so you at least get conflict markers to resolve by hand:"
    echo
    if git apply --3way --whitespace=fix "$PATCH_FILE"; then
        echo "  3-way apply succeeded with no conflicts (unexpected but great)."
    else
        echo
        echo "  Some files have conflict markers (<<<<<<< / ======= / >>>>>>>)."
        echo "  Conflicted files:"
        git diff --name-only --diff-filter=U | sed 's/^/    - /'
        echo
        echo "  Open each of those files, resolve the <<<<<<< / ======= / >>>>>>>"
        echo "  blocks by hand (git blame / git log on the file will show you"
        echo "  what changed on master since this patch was made), then run:"
        echo "    git add -A && git commit -m 'Resolve ethernet-over-usb conflicts'"
        echo "  and re-run this script with --skip-build removed once resolved,"
        echo "  or just continue manually with idf.py build."
        exit 2
    fi
fi

if [[ "$DO_BUILD" -eq 0 ]]; then
    echo
    echo "Patch applied. Skipping build (--skip-build). Source is ready in:"
    echo "  $REPO_DIR"
    exit 0
fi

mkdir -p "$OUT_DIR"

echo
echo "=== 3/5: Building firmware (mode: $BUILD_MODE) ==="
if [[ "$BUILD_MODE" == "docker" ]]; then
    if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker not found. Install Docker or re-run with --native" >&2
        echo "       (after sourcing ESP-IDF's export.sh yourself)." >&2
        exit 1
    fi
    docker build -t espminer-build "$REPO_DIR/.devcontainer"
    docker run --rm \
        -v "$REPO_DIR:/workspace" \
        -w /workspace \
        espminer-build \
        bash -c "git config --global --add safe.directory /workspace && idf.py set-target esp32s3 && idf.py build"
else
    if [[ -z "${IDF_PATH:-}" ]]; then
        echo "ERROR: --native requires ESP-IDF to be sourced first, e.g.:" >&2
        echo "         . \$HOME/esp/esp-idf/export.sh" >&2
        exit 1
    fi
    idf.py set-target esp32s3
    idf.py build
fi

echo
echo "=== 4/5: Collecting build outputs ==="
cp "$REPO_DIR/build/esp-miner.bin" "$OUT_DIR/esp-miner.bin"
cp "$REPO_DIR/build/www.bin" "$OUT_DIR/www.bin"
echo "  -> $OUT_DIR/esp-miner.bin"
echo "  -> $OUT_DIR/www.bin"

echo
echo "=== 5/5: Building merged flashable image ==="
( cd "$REPO_DIR" && ./merge_bin.sh ./esp-miner-merged.bin )
cp "$REPO_DIR/esp-miner-merged.bin" "$OUT_DIR/esp-miner-merged.bin"
echo "  -> $OUT_DIR/esp-miner-merged.bin"

cp "$REPO_DIR/config-${BOARD_CONFIG}.cvs" "$OUT_DIR/config-${BOARD_CONFIG}.cvs" 2>/dev/null || true

cat <<EOF

Done. Outputs are in: $OUT_DIR
  - esp-miner.bin           (firmware app image)
  - www.bin                 (AxeOS web UI image)
  - esp-miner-merged.bin    (bootloader+partition+app+www+ota, single flashable image)
  - config-${BOARD_CONFIG}.cvs        (NVS config for board version ${BOARD_CONFIG} / Gamma)

To flash a factory-fresh device (wipes settings), from OUTSIDE any container,
with the Bitaxe connected via USB:
  pip install bitaxetool --break-system-packages   # if not already installed
  bitaxetool --config "$OUT_DIR/config-${BOARD_CONFIG}.cvs" --firmware "$OUT_DIR/esp-miner-merged.bin"

To update firmware on a device that's already configured (keeps your
settings), use AxeOS's web UI "Firmware Update" page with esp-miner.bin
and www.bin, or OTA via the API.

Once flashed, go to the web UI's Network settings page and set
"Network Mode" to Ethernet-over-USB.
EOF
