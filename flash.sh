#!/usr/bin/env bash
# =============================================================================
# flash.sh — Extract tegraflash archive and flash Jetson Orin Nano
# =============================================================================
# Usage: ./flash.sh [OPTIONS]
#
# This script:
#   1. Installs required host dependencies (device-tree-compiler, etc.)
#   2. Locates the tegraflash tarball in the build deploy directory
#   3. Removes any previously extracted files from the build deploy directory
#      (keeps the directory clean; the tarball itself is preserved)
#   4. Extracts the tarball into flash-artifacts/<MACHINE>/ (never into build/)
#   5. Optionally verifies the Jetson is in USB recovery mode (0955:7523)
#   6. Runs sudo ./doflash.sh from the extracted directory
#
# Options:
#   --machine MACHINE   Yocto MACHINE name (default: jetson-orin-nano-devkit-nvme)
#   --image   IMAGE     Image recipe name  (default: demo-image-base)
#   --no-flash          Extract only; do not run doflash.sh
#   --no-cleanup        Keep flash-artifacts/ after flashing
#   --skip-deps         Skip host dependency installation check
#   -h, --help          Show this help
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
MACHINE="jetson-orin-nano-devkit-nvme"
IMAGE="demo-image-base"
DO_FLASH="yes"
DO_CLEANUP="yes"
SKIP_DEPS="no"

# ---------------------------------------------------------------------------
# Color helpers (consistent with build.sh)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
die()   { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//' | sed -n '/^flash.sh/,/^=\+/p'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --machine)   MACHINE="$2";  shift 2 ;;
        --image)     IMAGE="$2";    shift 2 ;;
        --no-flash)  DO_FLASH="no"; shift ;;
        --no-cleanup) DO_CLEANUP="no"; shift ;;
        --skip-deps) SKIP_DEPS="yes"; shift ;;
        -h|--help)   usage ;;
        *) die "Unknown option: $1. Run with --help for usage." ;;
    esac
done

# ---------------------------------------------------------------------------
# Step 1: Install host dependencies
# ---------------------------------------------------------------------------
install_deps() {
    local missing=()

    command -v dtc    &>/dev/null || missing+=(device-tree-compiler)
    command -v lsusb  &>/dev/null || missing+=(usbutils)
    # tegrarcm_v2 ships inside the tarball; no host package needed

    if [[ ${#missing[@]} -gt 0 ]]; then
        step "Installing missing host packages: ${missing[*]}"
        if command -v sudo &>/dev/null && command -v apt-get &>/dev/null; then
            sudo apt-get update -qq
            sudo apt-get install -y "${missing[@]}"
        else
            die "Cannot auto-install packages on this system. Please install manually: ${missing[*]}"
        fi
    else
        info "Host dependencies satisfied."
    fi
}

if [[ "${SKIP_DEPS}" == "no" ]]; then
    step "Checking host dependencies..."
    install_deps
fi

# ---------------------------------------------------------------------------
# Step 2: Locate the tegraflash tarball
# ---------------------------------------------------------------------------
DEPLOY_DIR="${SCRIPT_DIR}/build/tmp/deploy/images/${MACHINE}"
TARBALL="${DEPLOY_DIR}/${IMAGE}-${MACHINE}.rootfs.tegraflash.tar.gz"

# Resolve symlink if present
if [[ -L "${TARBALL}" ]]; then
    TARBALL="$(readlink -f "${TARBALL}")"
fi

if [[ ! -f "${TARBALL}" ]]; then
    die "Tegraflash tarball not found: ${TARBALL}
  Build the image first with:
    ./build.sh --rootfs rw --no-dm-verity   # development build
    ./build.sh                               # production build"
fi

info "Found tarball: ${TARBALL}"

# ---------------------------------------------------------------------------
# Step 3: Clean previously extracted files from the build deploy directory
# ---------------------------------------------------------------------------
step "Cleaning any previously extracted flash artifacts from ${DEPLOY_DIR}..."

# List all members of the tarball and remove them from the deploy directory.
# This undoes any manual extraction done during troubleshooting.
tar -tzf "${TARBALL}" | while IFS= read -r entry; do
    # Strip trailing slash (directories)
    local_path="${DEPLOY_DIR}/${entry%/}"
    if [[ -f "${local_path}" || -L "${local_path}" ]]; then
        rm -f "${local_path}"
    elif [[ -d "${local_path}" && "${entry}" == */ ]]; then
        # Only remove empty directories to avoid accidentally removing build outputs
        rmdir --ignore-fail-on-non-empty "${local_path}" 2>/dev/null || true
    fi
done

# Also remove common residual files left by interactive troubleshooting
for residual in cvm.bin cvm.bin.bak chip_info.bin chip_info.bin_bak; do
    rm -f "${DEPLOY_DIR}/${residual}"
done
find "${DEPLOY_DIR}" -maxdepth 1 -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find "${DEPLOY_DIR}" -maxdepth 1 -name 'temp'        -type d -exec rm -rf {} + 2>/dev/null || true

info "Build deploy directory is clean."

# ---------------------------------------------------------------------------
# Step 4: Extract tarball into flash-artifacts/
# ---------------------------------------------------------------------------
ARTIFACTS_DIR="${SCRIPT_DIR}/flash-artifacts/${MACHINE}"
step "Extracting flash artifacts to ${ARTIFACTS_DIR}..."

rm -rf "${ARTIFACTS_DIR}"
mkdir -p "${ARTIFACTS_DIR}"

# Register cleanup trap (unless --no-cleanup)
if [[ "${DO_CLEANUP}" == "yes" ]]; then
    trap 'info "Cleaning up ${ARTIFACTS_DIR}..."; rm -rf "${SCRIPT_DIR}/flash-artifacts"' EXIT
fi

tar -xzf "${TARBALL}" -C "${ARTIFACTS_DIR}"

if [[ ! -f "${ARTIFACTS_DIR}/doflash.sh" ]]; then
    die "doflash.sh not found after extraction — tarball may be corrupt or from an unexpected build."
fi

info "Extraction complete."

# ---------------------------------------------------------------------------
# Step 5: Verify recovery mode
# ---------------------------------------------------------------------------
step "Checking USB recovery mode..."

RECOVERY_USB_ID="0955:7523"
BOOTED_USB_ID="0955:7020"

if command -v lsusb &>/dev/null; then
    if lsusb 2>/dev/null | grep -q "${RECOVERY_USB_ID}"; then
        info "Jetson detected in APX recovery mode (${RECOVERY_USB_ID}). Ready to flash."
    elif lsusb 2>/dev/null | grep -q "${BOOTED_USB_ID}"; then
        warn "Jetson appears to be in normal boot mode (${BOOTED_USB_ID}), not recovery mode."
        warn "Enter recovery mode before flashing:"
        warn "  1. Hold the Force Recovery button (FC_REC)"
        warn "  2. Tap Reset (or power on)"
        warn "  3. Release Force Recovery after 2 seconds"
        warn "  4. Verify: lsusb | grep 0955:7523"
        if [[ "${DO_FLASH}" == "yes" ]]; then
            warn "Proceeding anyway — flash may fail if device is not in recovery mode."
        fi
    else
        warn "No Jetson USB device detected. Verify the USB-C cable and recovery mode."
        warn "  Recovery mode: lsusb should show  0955:7523  (APX)"
        warn "  Normal boot:   lsusb would show   0955:7020"
        if [[ "${DO_FLASH}" == "yes" ]]; then
            warn "Proceeding anyway — flash will fail if device is not connected."
        fi
    fi
else
    warn "lsusb not available; skipping USB device check."
fi

# ---------------------------------------------------------------------------
# Step 6: Flash
# ---------------------------------------------------------------------------
if [[ "${DO_FLASH}" == "no" ]]; then
    info "Skipping flash (--no-flash). Artifacts are in: ${ARTIFACTS_DIR}"
    # Disable the cleanup trap so artifacts persist
    trap - EXIT
    exit 0
fi

step "Flashing ${MACHINE} via doflash.sh..."
echo ""
echo "  *** This requires sudo — you may be prompted for your password. ***"
echo ""

cd "${ARTIFACTS_DIR}"
sudo ./doflash.sh

echo ""
info "Flash complete. The board should reboot automatically."
info "Connect serial: screen /dev/ttyACM0 115200"
