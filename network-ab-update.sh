#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHINE="jetson-orin-nano-devkit-nvme"
IMAGE_BASENAME="demo-image-base"
DEPLOY_DIR="${SCRIPT_DIR}/build/tmp/deploy/images/${MACHINE}"
SSH_USER="root"
SSH_HOST=""
SSH_PORT="22"
SSH_IDENTITY=""
IMAGE_PATH=""
REBOOT_AFTER="no"
TARGET_SLOT_OVERRIDE=""
declare -a SSH_EXTRA_OPTS=()

usage() {
    sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'
}

# network-ab-update.sh — Update the inactive A/B rootfs slot over SSH
#
# This script is intended for devices that have already been provisioned with
# the repo's NVMe A/B layout over USB recovery flashing.
#
# It does NOT:
# - repartition the disk
# - update QSPI bootloader partitions
# - replace the initrd tegraflash USB flow
#
# It DOES:
# - stream a Yocto-generated rootfs ext4 image to the inactive slot
# - mark the other slot active using nvbootctrl
# - optionally reboot into the updated slot
#
# Current limitation:
# - this helper is for rw / non-dm-verity images only
#
# Usage:
#   ./network-ab-update.sh --host 10.0.0.60 [--reboot]
#   ./network-ab-update.sh --host jetson.local --image /path/to/rootfs.ext4
#   ./network-ab-update.sh --host 10.0.0.60 --target-slot B --reboot

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

find_default_image() {
    local latest
    latest="$(find "${DEPLOY_DIR}" -maxdepth 1 -type f -name "${IMAGE_BASENAME}-${MACHINE}.rootfs-*.ext4" | sort | tail -n 1 || true)"
    if [[ -n "${latest}" ]]; then
        printf '%s\n' "${latest}"
        return
    fi

    latest="${DEPLOY_DIR}/${IMAGE_BASENAME}-${MACHINE}.rootfs.ext4"
    [[ -f "${latest}" ]] || die "Could not find a rootfs ext4 image in ${DEPLOY_DIR}"
    printf '%s\n' "${latest}"
}

ssh_base=(ssh -p "${SSH_PORT}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                SSH_HOST="${2:-}"
                shift 2
                ;;
            --user)
                SSH_USER="${2:-}"
                shift 2
                ;;
            --port)
                SSH_PORT="${2:-}"
                shift 2
                ;;
            --identity)
                SSH_IDENTITY="${2:-}"
                shift 2
                ;;
            --image)
                IMAGE_PATH="${2:-}"
                shift 2
                ;;
            --deploy-dir)
                DEPLOY_DIR="${2:-}"
                shift 2
                ;;
            --target-slot)
                TARGET_SLOT_OVERRIDE="${2:-}"
                shift 2
                ;;
            --ssh-option)
                SSH_EXTRA_OPTS+=("${2:-}")
                shift 2
                ;;
            --reboot)
                REBOOT_AFTER="yes"
                shift
                ;;
            --no-reboot)
                REBOOT_AFTER="no"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

parse_args "$@"

[[ -n "${SSH_HOST}" ]] || die "Missing --host"
[[ -n "${SSH_USER}" ]] || die "Missing --user"

if [[ -n "${SSH_IDENTITY}" ]]; then
    ssh_base+=(-i "${SSH_IDENTITY}")
fi

for opt in "${SSH_EXTRA_OPTS[@]}"; do
    ssh_base+=(-o "${opt}")
done

REMOTE="${SSH_USER}@${SSH_HOST}"
ssh_cmd=("${ssh_base[@]}" "${REMOTE}")

if [[ -z "${IMAGE_PATH}" ]]; then
    IMAGE_PATH="$(find_default_image)"
fi

[[ -f "${IMAGE_PATH}" ]] || die "Image not found: ${IMAGE_PATH}"

TESTDATA_PATH="${IMAGE_PATH%.ext4}.testdata.json"
if [[ ! -f "${TESTDATA_PATH}" ]]; then
    TESTDATA_PATH="${DEPLOY_DIR}/${IMAGE_BASENAME}-${MACHINE}.rootfs.testdata.json"
fi

if [[ -f "${TESTDATA_PATH}" ]] && grep -qE '"IMAGE_CLASSES".*dm-verity-img|dm-verity-img' "${TESTDATA_PATH}"; then
    die "The selected image appears to use dm-verity. This network helper currently supports rw / non-dm-verity images only."
fi

info "Checking SSH connectivity to ${REMOTE}..."
"${ssh_cmd[@]}" "true"

info "Checking required tools on the device..."
"${ssh_cmd[@]}" "command -v nvbootctrl >/dev/null && command -v dd >/dev/null && command -v gzip >/dev/null"

current_slot_raw="$("${ssh_cmd[@]}" "nvbootctrl get-current-slot" | tr -d '\r' | tail -n 1)"
case "${current_slot_raw}" in
    0)
        current_slot_name="A"
        current_rootfs="/dev/nvme0n1p1"
        inactive_slot="1"
        inactive_slot_name="B"
        inactive_rootfs="/dev/nvme0n1p2"
        ;;
    1)
        current_slot_name="B"
        current_rootfs="/dev/nvme0n1p2"
        inactive_slot="0"
        inactive_slot_name="A"
        inactive_rootfs="/dev/nvme0n1p1"
        ;;
    *)
        die "Unexpected current slot from nvbootctrl: ${current_slot_raw}"
        ;;
esac

if [[ -n "${TARGET_SLOT_OVERRIDE}" ]]; then
    case "${TARGET_SLOT_OVERRIDE}" in
        A|a)
            target_slot="0"
            target_slot_name="A"
            target_rootfs="/dev/nvme0n1p1"
            ;;
        B|b)
            target_slot="1"
            target_slot_name="B"
            target_rootfs="/dev/nvme0n1p2"
            ;;
        *)
            die "Invalid --target-slot value: ${TARGET_SLOT_OVERRIDE} (use A or B)"
            ;;
    esac
else
    target_slot="${inactive_slot}"
    target_slot_name="${inactive_slot_name}"
    target_rootfs="${inactive_rootfs}"
fi

[[ "${target_slot}" != "${current_slot_raw}" ]] || die "Target slot ${target_slot_name} is already active; refusing to overwrite the running rootfs."

image_name="$(basename "${IMAGE_PATH}")"
requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

info "Current slot: ${current_slot_name} (${current_rootfs})"
info "Target slot:  ${target_slot_name} (${target_rootfs})"
info "Image:        ${IMAGE_PATH}"

info "Preparing update status markers on the device..."
"${ssh_cmd[@]}" "mkdir -p /data/physical-ai-update && printf '%s\n' '${target_slot}' > /data/physical-ai-update/pending-slot && printf '%s\n' '${image_name}' > /data/physical-ai-update/pending-build && printf '%s\n' '${requested_at}' > /data/physical-ai-update/pending-requested-at"

info "Streaming rootfs image to inactive slot ${target_slot_name}..."
gzip -1 -c "${IMAGE_PATH}" | "${ssh_cmd[@]}" "gzip -d | dd of='${target_rootfs}' bs=4M"

info "Syncing target slot..."
"${ssh_cmd[@]}" "sync"

info "Marking slot ${target_slot_name} active for next boot..."
"${ssh_cmd[@]}" "nvbootctrl set-active-boot-slot '${target_slot}'"

info "Update staged successfully."
echo "Current slot : ${current_slot_name}"
echo "Next slot    : ${target_slot_name}"
echo "Image        : ${image_name}"

if [[ "${REBOOT_AFTER}" == "yes" ]]; then
    info "Rebooting the device into slot ${target_slot_name}..."
    "${ssh_cmd[@]}" "reboot"
else
    echo
    echo "Reboot when you are ready:"
    echo "  ssh -p ${SSH_PORT} ${REMOTE} reboot"
fi
