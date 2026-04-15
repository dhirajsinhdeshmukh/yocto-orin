#!/usr/bin/env bash
# =============================================================================
# flash.sh — Extract tegraflash archive and flash Jetson Orin Nano
# =============================================================================
# Usage: ./flash.sh [OPTIONS]
#
# This script:
#   1. Installs required host dependencies (device-tree-compiler, etc.)
#   2. Locates the tegraflash tarball in the build deploy directory
#   3. Extracts the tarball into flash-artifacts/<MACHINE>/ (never into build/)
#   4. Optionally verifies the Jetson is in USB recovery mode (0955:7523)
#   5. Runs sudo ./doflash.sh from the extracted directory
#
# Options:
#   --machine MACHINE   Yocto MACHINE name (default: jetson-orin-nano-devkit-nvme)
#   --image   IMAGE     Image recipe name  (default: demo-image-base)
#   --nvme-only         Shorthand for --machine jetson-orin-nano-devkit-nvme
#   --usb-instance N    Forward --usb-instance to doflash.sh
#   --erase-nvme        Forward --erase-nvme to doflash.sh
#   --force             Continue even if recovery mode is not detected
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
NVME_ONLY="no"
FORCE="no"
USB_INSTANCE=""
ERASE_NVME="no"
ARTIFACTS_DIR=""
PRESERVE_ARTIFACTS="no"
FLASH_RUNNER="doflash.sh"

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

cleanup_flash_artifacts() {
    local exit_code="$1"

    if [[ -z "${ARTIFACTS_DIR}" || ! -d "${ARTIFACTS_DIR}" ]]; then
        return
    fi

    if [[ "${DO_CLEANUP}" != "yes" || "${PRESERVE_ARTIFACTS}" == "yes" || "${exit_code}" -ne 0 ]]; then
        info "Preserving flash artifacts in ${ARTIFACTS_DIR}"
        return
    fi

    info "Cleaning up ${ARTIFACTS_DIR}..."
    if command -v sudo &>/dev/null; then
        sudo chmod -R u+rwx "${SCRIPT_DIR}/flash-artifacts" 2>/dev/null || true
        sudo rm -rf "${SCRIPT_DIR}/flash-artifacts" 2>/dev/null || true
    else
        chmod -R u+rwx "${SCRIPT_DIR}/flash-artifacts" 2>/dev/null || true
        rm -rf "${SCRIPT_DIR}/flash-artifacts" 2>/dev/null || true
    fi
}

print_flash_logs() {
    local found="no"
    local path

    if [[ -z "${ARTIFACTS_DIR}" || ! -d "${ARTIFACTS_DIR}" ]]; then
        return
    fi

    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        if [[ "${found}" == "no" ]]; then
            warn "Flash logs and preserved output:"
            found="yes"
        fi
        echo "  ${path}"
    done < <(find "${ARTIFACTS_DIR}" -maxdepth 1 \( -type f \( -name 'log.initrd-flash.*' -o -name 'rcm-boot.output' \) -o -type d -name 'device-logs-*' \) | sort)
}

trap 'cleanup_flash_artifacts "$?"' EXIT

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
        --nvme-only) NVME_ONLY="yes"; MACHINE="jetson-orin-nano-devkit-nvme"; shift ;;
        --usb-instance) USB_INSTANCE="$2"; shift 2 ;;
        --erase-nvme) ERASE_NVME="yes"; shift ;;
        --no-flash)  DO_FLASH="no"; shift ;;
        --no-cleanup) DO_CLEANUP="no"; shift ;;
        --skip-deps) SKIP_DEPS="yes"; shift ;;
        --force) FORCE="yes"; shift ;;
        -h|--help)   usage ;;
        *) die "Unknown option: $1. Run with --help for usage." ;;
    esac
done

if [[ "${NVME_ONLY}" == "yes" && "${MACHINE}" != "jetson-orin-nano-devkit-nvme" ]]; then
    die "Cannot combine --nvme-only with --machine. Use only one of those options."
fi

# ---------------------------------------------------------------------------
# Step 1: Install host dependencies
# ---------------------------------------------------------------------------
install_deps() {
    local missing=()

    command -v dtc    &>/dev/null || missing+=(device-tree-compiler)
    command -v lsusb  &>/dev/null || missing+=(usbutils)
    command -v udisksctl &>/dev/null || missing+=(udisks2)
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

find_tegraflash_tarball() {
    local deploy_dir="$1"
    local image="$2"
    local machine="$3"
    local preferred="${deploy_dir}/${image}-${machine}.rootfs.tegraflash.tar.gz"
    local resolved=""
    local candidate=""
    local -a matches=()

    if [[ -f "${preferred}" || -L "${preferred}" ]]; then
        resolved="$(readlink -f "${preferred}" 2>/dev/null || true)"
        if [[ -n "${resolved}" && -f "${resolved}" ]]; then
            printf '%s\n' "${resolved}"
            return 0
        fi
        if [[ -f "${preferred}" ]]; then
            printf '%s\n' "${preferred}"
            return 0
        fi
    fi

    if [[ -d "${deploy_dir}" ]]; then
        while IFS= read -r candidate; do
            matches+=("${candidate}")
        done < <(find "${deploy_dir}" -maxdepth 1 \( -type f -o -type l \) -name "${image}-${machine}.rootfs-*.tegraflash.tar.gz" | sort)
    fi

    if [[ "${#matches[@]}" -gt 0 ]]; then
        candidate="${matches[$(("${#matches[@]}" - 1))]}"
        resolved="$(readlink -f "${candidate}" 2>/dev/null || true)"
        if [[ -n "${resolved}" && -f "${resolved}" ]]; then
            printf '%s\n' "${resolved}"
            return 0
        fi
        if [[ -f "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    fi

    return 1
}

if [[ "${SKIP_DEPS}" == "no" ]]; then
    step "Checking host dependencies..."
    install_deps
fi

# ---------------------------------------------------------------------------
# Step 2: Locate the tegraflash tarball
# ---------------------------------------------------------------------------
DEPLOY_DIR="${SCRIPT_DIR}/build/tmp/deploy/images/${MACHINE}"
TARBALL="$(find_tegraflash_tarball "${DEPLOY_DIR}" "${IMAGE}" "${MACHINE}" || true)"

if [[ -z "${TARBALL}" || ! -f "${TARBALL}" ]]; then
    die "Tegraflash tarball not found in: ${DEPLOY_DIR}
  Looked for:
    ${IMAGE}-${MACHINE}.rootfs.tegraflash.tar.gz
    ${IMAGE}-${MACHINE}.rootfs-*.tegraflash.tar.gz
  Build the image first with:
    ./build.sh --rootfs rw --no-dm-verity   # development build
    ./build.sh                               # production build"
fi

info "Found tarball: ${TARBALL}"

# ---------------------------------------------------------------------------
# Step 3: Extract tarball into flash-artifacts/
# ---------------------------------------------------------------------------
ARTIFACTS_DIR="${SCRIPT_DIR}/flash-artifacts/${MACHINE}"
step "Extracting flash artifacts to ${ARTIFACTS_DIR}..."

if [[ -d "${ARTIFACTS_DIR}" ]]; then
    if command -v sudo &>/dev/null; then
        sudo chmod -R u+rwx "${ARTIFACTS_DIR}" 2>/dev/null || true
        sudo rm -rf "${ARTIFACTS_DIR}" 2>/dev/null || true
    else
        chmod -R u+rwx "${ARTIFACTS_DIR}" 2>/dev/null || true
        rm -rf "${ARTIFACTS_DIR}" 2>/dev/null || true
    fi
fi
mkdir -p "${ARTIFACTS_DIR}"

tar -xzf "${TARBALL}" -C "${ARTIFACTS_DIR}"

if [[ ! -f "${ARTIFACTS_DIR}/doflash.sh" ]]; then
    die "doflash.sh not found after extraction — tarball may be corrupt or from an unexpected build."
fi

info "Extraction complete."

step "Summarizing initrd flash configuration..."
if [[ -f "${ARTIFACTS_DIR}/.env.initrd-flash" ]]; then
    declare -A DEFAULTS=()
    # shellcheck source=/dev/null
    source "${ARTIFACTS_DIR}/.env.initrd-flash"

    if [[ "${EXTERNAL_ROOTFS_DRIVE:-0}" == "1" ]]; then
        if [[ -f "${ARTIFACTS_DIR}/initrd-flash" ]]; then
            FLASH_RUNNER="initrd-flash"
        else
            die "External NVMe flash requested, but initrd-flash is missing from ${ARTIFACTS_DIR}."
        fi
    fi

    echo ""
    echo "  Flash mode:       initrd-flash"
    echo "  Machine:          ${MACHINE}"
    echo "  Boot device:      ${BOOTDEV:-unknown}"
    echo "  Rootfs device:    ${ROOTFS_DEVICE:-unknown}"
    echo "  External rootfs:  ${EXTERNAL_ROOTFS_DRIVE:-0}"
    echo "  Flash runner:     ${FLASH_RUNNER}"
    echo "  USB instance:     ${USB_INSTANCE:-auto-detect}"
    echo "  Erase NVMe:       ${ERASE_NVME}"
    if [[ "${EXTERNAL_ROOTFS_DRIVE:-0}" == "1" ]]; then
        echo "  Note:             External NVMe initrd flash; the board will reboot mid-flash by design."
        echo "  Note:             After reboot, the host waits for USB storage handoff and uses udisksctl to mount the flash package."
    else
        echo "  Note:             Internal-storage flash; a mid-flash reboot is still expected during initrd handoff."
    fi
    echo ""
else
    warn "Missing ${ARTIFACTS_DIR}/.env.initrd-flash; continuing without initrd flash summary."
fi

# ---------------------------------------------------------------------------
# Step 4: Verify recovery mode
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
            if [[ "${FORCE}" == "yes" ]]; then
                warn "Proceeding anyway due to --force. Flash may still fail if device is not connected."
            else
                die "Jetson recovery device not detected. Aborting flash. Use --force to override."
            fi
        fi
    fi
else
    warn "lsusb not available; skipping USB device check."
fi

# ---------------------------------------------------------------------------
# Step 5: Flash
# ---------------------------------------------------------------------------
if [[ "${DO_FLASH}" == "no" ]]; then
    info "Skipping flash (--no-flash). Artifacts are in: ${ARTIFACTS_DIR}"
    PRESERVE_ARTIFACTS="yes"
    exit 0
fi

step "Flashing ${MACHINE} via ${FLASH_RUNNER}..."
echo ""
echo "  *** This requires sudo — you may be prompted for your password. ***"
echo ""

DOFLASH_ARGS=()
if [[ -n "${USB_INSTANCE}" ]]; then
    DOFLASH_ARGS+=(--usb-instance "${USB_INSTANCE}")
fi
if [[ "${ERASE_NVME}" == "yes" ]]; then
    DOFLASH_ARGS+=(--erase-nvme)
fi

cd "${ARTIFACTS_DIR}"
if sudo "./${FLASH_RUNNER}" "${DOFLASH_ARGS[@]}"; then
    echo ""
    info "Flash complete. The board should reboot automatically."
    info "Recovery USB is not a boot console. For early boot logs, use the Jetson UART debug header with a USB-UART adapter."
else
    FLASH_EXIT_CODE=$?
    PRESERVE_ARTIFACTS="yes"
    echo ""
    warn "Flash failed with exit code ${FLASH_EXIT_CODE}. The extracted flash artifacts have been preserved."
    print_flash_logs
    exit "${FLASH_EXIT_CODE}"
fi
