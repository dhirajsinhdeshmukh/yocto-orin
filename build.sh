#!/usr/bin/env bash
# =============================================================================
# build.sh — Yocto build orchestrator for Jetson Orin Nano BSP
# =============================================================================
# Wraps `kas build` with runtime flags for CPU allocation, rootfs mode,
# and dm-verity toggle. Generates a temporary kas override YAML that is
# merged with the base kas-project.yml at build time.
#
# Usage:
#   ./build.sh [OPTIONS] [-- KAS_BUILD_ARGS [-- BITBAKE_ARGS]]
#
# Examples:
#   ./build.sh --cores 8 --rootfs ro --dm-verity               # production
#   ./build.sh --cores 4 --rootfs overlayfs --dm-verity         # field debug
#   ./build.sh --rootfs rw --no-dm-verity                       # dev iteration
#   ./build.sh --rootfs rw --no-dm-verity --flash-artifacts-only # refresh staged tegraflash bundle only
#   ./build.sh --cpu-affinity 0-3 --cores 4                     # pinned build
#   ./build.sh -- --target demo-image-base -c populate_sdk         # build SDK
# =============================================================================
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-activate the project venv if kas isn't already on PATH
if ! command -v kas >/dev/null 2>&1 && [[ -f "${SCRIPT_DIR}/.venv/bin/activate" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/.venv/bin/activate"
fi

KAS_BASE="${SCRIPT_DIR}/kas-project.yml"
DEFAULT_MACHINE="$(awk '$1 == "machine:" { print $2; exit }' "${KAS_BASE}")"
DEFAULT_TARGET="$(awk '
    /^target:/ { in_target=1; next }
    in_target && $1 == "-" { print $2; exit }
    in_target && NF == 0 { exit }
' "${KAS_BASE}")"
CORES=""
CPU_AFFINITY=""
MACHINE="${DEFAULT_MACHINE}"
ROOTFS_MODE="ro"         # ro | rw | overlayfs
DM_VERITY="on"           # on | off
TARGET=""
FLASH_ARTIFACTS_ONLY="no"
EXTRA_KAS_ARGS=()

# ── Color helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: ./build.sh [OPTIONS] [-- KAS_BUILD_ARGS [-- BITBAKE_ARGS]]

Options:
  -c, --cores N            Number of CPU cores for BB_NUMBER_THREADS / PARALLEL_MAKE
                           (default: 80% of available cores)
  -a, --cpu-affinity MASK  CPU affinity mask for taskset (e.g., 0-7 or 0,2,4,6)
  -m, --machine MACHINE    Override Yocto MACHINE (default: from kas-project.yml)
  -r, --rootfs MODE        Rootfs mode: ro | rw | overlayfs  (default: ro)
  -d, --dm-verity          Enable dm-verity signing  (default)
      --no-dm-verity       Disable dm-verity signing
  -t, --target IMAGE       Override bitbake target (default: from kas-project.yml)
      --flash-artifacts-only
                           Rebuild and stage only the tegraflash bundle for the
                           selected image target
  -h, --help               Show this help

Arguments after the first -- are passed to `kas build`. Arguments after a
second -- are forwarded to BitBake itself, e.g.:
  ./build.sh -- --target demo-image-base -c populate_sdk
  ./build.sh -- --target demo-image-base -c rootfs -- -f
EOF
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--cores)        CORES="$2"; shift 2 ;;
        -a|--cpu-affinity) CPU_AFFINITY="$2"; shift 2 ;;
        -m|--machine)      MACHINE="$2"; shift 2 ;;
        -r|--rootfs)       ROOTFS_MODE="$2"; shift 2 ;;
        -d|--dm-verity)    DM_VERITY="on"; shift ;;
        --no-dm-verity)    DM_VERITY="off"; shift ;;
        -t|--target)       TARGET="$2"; shift 2 ;;
        --flash-artifacts-only) FLASH_ARTIFACTS_ONLY="yes"; shift ;;
        -h|--help)         usage ;;
        --)                shift; EXTRA_KAS_ARGS=("$@"); break ;;
        *)                 die "Unknown option: $1  (use -h for help)" ;;
    esac
done

# ── Validate inputs ──────────────────────────────────────────────────────────
[[ "$ROOTFS_MODE" =~ ^(ro|rw|overlayfs)$ ]] || die "Invalid --rootfs mode: $ROOTFS_MODE (must be ro|rw|overlayfs)"
[[ -n "$MACHINE" ]] || die "Could not determine a default machine from ${KAS_BASE}. Use --machine."
command -v kas >/dev/null 2>&1 || die "kas not found. Install: pip install kas"

if [[ "${FLASH_ARTIFACTS_ONLY}" == "yes" && ${#EXTRA_KAS_ARGS[@]} -gt 0 ]]; then
    die "--flash-artifacts-only does not accept extra kas/bitbake arguments after --. Use --target if you need a different image."
fi

if [[ "$DM_VERITY" == "on" ]]; then
    KEY="${SCRIPT_DIR}/keys/dm-verity/rsa3k-key.pem"
    CERT="${SCRIPT_DIR}/keys/dm-verity/rsa3k-cert.pem"
    [[ -f "$KEY" ]]  || die "dm-verity signing key not found: $KEY\n  Generate with: ./build.sh --help  (see README.md § DM-Verity Signing)"
    [[ -f "$CERT" ]] || die "dm-verity signing cert not found: $CERT"
fi

# ── Compute core count ───────────────────────────────────────────────────────
TOTAL_CORES=$(nproc)
if [[ -z "$CORES" ]]; then
    CORES=$(( TOTAL_CORES * 80 / 100 ))
    [[ "$CORES" -lt 1 ]] && CORES=1
fi
info "Build parallelism: ${CORES} threads (of ${TOTAL_CORES} available)"

# ── Generate kas override YAML ───────────────────────────────────────────────
# kas 5.2+ requires all concatenated configs to live in the same repo.
# Write the override under SCRIPT_DIR/tmp/ which is gitignored.
mkdir -p "${SCRIPT_DIR}/tmp"
OVERRIDE_FILE=$(mktemp "${SCRIPT_DIR}/tmp/kas-override-XXXXXX.yml")
trap 'rm -f "$OVERRIDE_FILE"' EXIT

cat > "$OVERRIDE_FILE" <<YAML
# Auto-generated by build.sh — $(date -Iseconds)
# DO NOT EDIT — this file is regenerated on every build invocation.
header:
  version: 14

machine: ${MACHINE}

local_conf_header:
  build-sh-cores: |
    BB_NUMBER_THREADS = "${CORES}"
    PARALLEL_MAKE = "-j ${CORES}"
YAML

# ── Rootfs mode injection ────────────────────────────────────────────────────
case "$ROOTFS_MODE" in
    ro)
        info "Rootfs mode: read-only (hardened)"
        cat >> "$OVERRIDE_FILE" <<'YAML'
  build-sh-rootfs: |
    IMAGE_FEATURES:append = " read-only-rootfs"
    SYSTEMD_ROOTFS_RO_DROPIN = "1"
YAML
        ;;
    rw)
        warn "Rootfs mode: read-write (development only — NOT for production)"
        cat >> "$OVERRIDE_FILE" <<'YAML'
  build-sh-rootfs: |
    IMAGE_FEATURES:remove = "read-only-rootfs"
    SYSTEMD_ROOTFS_RO_DROPIN = "0"
YAML
        ;;
    overlayfs)
        info "Rootfs mode: overlayfs (tmpfs-backed volatile writable layer)"
        cat >> "$OVERRIDE_FILE" <<'YAML'
  build-sh-rootfs: |
    IMAGE_FEATURES:append = " read-only-rootfs"
    IMAGE_INSTALL:append = " overlayfs-setup"
    SYSTEMD_ROOTFS_RO_DROPIN = "1"
YAML
        ;;
esac

# ── dm-verity toggle ─────────────────────────────────────────────────────────
if [[ "$DM_VERITY" == "off" ]]; then
    warn "dm-verity: DISABLED — image will NOT be integrity-protected"
    cat >> "$OVERRIDE_FILE" <<'YAML'
  build-sh-verity: |
    IMAGE_CLASSES:remove = "dm-verity-img"
    DM_VERITY_IMAGE = ""
YAML
else
    info "dm-verity: enabled (RSA-3K signed)"
fi

# ── Target override ──────────────────────────────────────────────────────────
if [[ -n "$TARGET" ]]; then
    cat >> "$OVERRIDE_FILE" <<YAML
target:
  - ${TARGET}
YAML
    info "Target override: ${TARGET}"
fi

IMAGE_TARGET="${TARGET:-${DEFAULT_TARGET}}"
if [[ "${FLASH_ARTIFACTS_ONLY}" == "yes" && -z "${IMAGE_TARGET}" ]]; then
    die "Could not determine the image target for --flash-artifacts-only. Use --target IMAGE."
fi

BUILD_MODE="standard build"
if [[ "${FLASH_ARTIFACTS_ONLY}" == "yes" ]]; then
    BUILD_MODE="flash-artifacts-only"
    info "Flash artifact refresh uses the selected image mode; pass the same --machine/--rootfs/--dm-verity settings as the image you plan to flash."
fi

# ── Build command assembly ───────────────────────────────────────────────────
KAS_BUILD_ARGS=()
BITBAKE_ARGS=()
if [[ ${#EXTRA_KAS_ARGS[@]} -gt 0 ]]; then
    SPLIT_EXTRA_ARGS="no"
    for arg in "${EXTRA_KAS_ARGS[@]}"; do
        if [[ "${SPLIT_EXTRA_ARGS}" == "no" && "${arg}" == "--" ]]; then
            SPLIT_EXTRA_ARGS="yes"
            continue
        fi

        if [[ "${SPLIT_EXTRA_ARGS}" == "yes" ]]; then
            BITBAKE_ARGS+=("${arg}")
        else
            KAS_BUILD_ARGS+=("${arg}")
        fi
    done
fi

KAS_CMD=(kas build "${KAS_BUILD_ARGS[@]}" "${KAS_BASE}:${OVERRIDE_FILE}")
if [[ ${#BITBAKE_ARGS[@]} -gt 0 ]]; then
    KAS_CMD+=(-- "${BITBAKE_ARGS[@]}")
fi

apply_cpu_affinity() {
    local -n cmd_ref=$1

    if [[ -n "$CPU_AFFINITY" ]]; then
        command -v taskset >/dev/null 2>&1 || die "taskset not found. Install: apt install util-linux"
        info "CPU affinity: taskset -c ${CPU_AFFINITY}"
        cmd_ref=(taskset -c "$CPU_AFFINITY" "${cmd_ref[@]}")
    fi
}

find_latest_flash_artifact() {
    local search_dir="$1"
    local image="$2"
    local machine="$3"
    local suffix="$4"

    find "${search_dir}" -maxdepth 1 -type f -name "${image}-${machine}.rootfs-*.tegraflash.${suffix}" | sort | tail -n1
}

promote_flash_artifacts() {
    local image="$1"
    local machine="$2"
    local work_dir
    local deploy_dir
    local latest_tar
    local latest_zip

    work_dir="$(find "${SCRIPT_DIR}/build/tmp/work" -type d -path "*/${image}/*/deploy-${image}-image-complete" | sort | tail -n1)"
    [[ -n "${work_dir}" ]] || die "Could not locate workdir deploy output for ${image}. Expected a deploy-${image}-image-complete directory."

    deploy_dir="${SCRIPT_DIR}/build/tmp/deploy/images/${machine}"
    mkdir -p "${deploy_dir}"

    latest_tar="$(find_latest_flash_artifact "${work_dir}" "${image}" "${machine}" "tar.gz")"
    [[ -n "${latest_tar}" ]] || die "No tegraflash tarball was produced in ${work_dir}"
    cp -f "${latest_tar}" "${deploy_dir}/"
    ln -sfn "$(basename "${latest_tar}")" "${deploy_dir}/${image}-${machine}.rootfs.tegraflash.tar.gz"
    info "Promoted $(basename "${latest_tar}") to ${deploy_dir}"

    latest_zip="$(find_latest_flash_artifact "${work_dir}" "${image}" "${machine}" "zip" || true)"
    if [[ -n "${latest_zip}" ]]; then
        cp -f "${latest_zip}" "${deploy_dir}/"
        ln -sfn "$(basename "${latest_zip}")" "${deploy_dir}/${image}-${machine}.rootfs.tegraflash.zip"
    fi
}

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
info "┌─────────────────────────────────────────────┐"
info "│  Jetson Orin Nano — Hardened BSP Build       │"
info "├─────────────────────────────────────────────┤"
info "│  Machine:    ${MACHINE}"
info "│  Cores:      ${CORES} / ${TOTAL_CORES}"
info "│  Affinity:   ${CPU_AFFINITY:-none (all cores)}"
info "│  Rootfs:     ${ROOTFS_MODE}"
info "│  dm-verity:  ${DM_VERITY}"
info "│  Mode:       ${BUILD_MODE}"
info "│  Target:     ${TARGET:-<from kas-project.yml>}"
info "│  Override:   ${OVERRIDE_FILE}"
info "└─────────────────────────────────────────────┘"
echo ""

# ── Execute ──────────────────────────────────────────────────────────────────
if [[ "${FLASH_ARTIFACTS_ONLY}" == "yes" ]]; then
    FLASH_REFRESH_CMD="bitbake ${IMAGE_TARGET} -c image_tegraflash -f"
    KAS_FLASH_CMD=(kas shell "${KAS_BASE}:${OVERRIDE_FILE}" -c "${FLASH_REFRESH_CMD}")
    apply_cpu_affinity KAS_FLASH_CMD

    info "Refreshing flash artifacts for ${IMAGE_TARGET}..."
    info "Executing: ${KAS_FLASH_CMD[*]}"
    "${KAS_FLASH_CMD[@]}"
    promote_flash_artifacts "${IMAGE_TARGET}" "${MACHINE}"
    exit 0
fi

apply_cpu_affinity KAS_CMD
info "Executing: ${KAS_CMD[*]}"
exec "${KAS_CMD[@]}"
