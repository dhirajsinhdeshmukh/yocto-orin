#!/bin/sh

set -eu

state_dir="/data/physical-ai-update"
runtime_dir="/var/lib/physical-ai"
message_file="${runtime_dir}/ab-update-message"

mkdir -p "${runtime_dir}"

[ -d "${state_dir}" ] || exit 0
[ -f "${state_dir}/pending-slot" ] || exit 0

current_slot="$(nvbootctrl get-current-slot 2>/dev/null || true)"
expected_slot="$(cat "${state_dir}/pending-slot" 2>/dev/null || true)"
pending_build="$(cat "${state_dir}/pending-build" 2>/dev/null || echo unknown-image)"
requested_at="$(cat "${state_dir}/pending-requested-at" 2>/dev/null || echo unknown-time)"

slot_name() {
    case "$1" in
        0) printf 'A' ;;
        1) printf 'B' ;;
        *) printf 'unknown' ;;
    esac
}

if [ -n "${current_slot}" ] && [ "${current_slot}" = "${expected_slot}" ]; then
    result="success"
    message="A/B update booted slot $(slot_name "${current_slot}") successfully using ${pending_build} requested at ${requested_at}."
else
    result="rollback"
    message="A/B update rollback detected. Expected slot $(slot_name "${expected_slot}") but booted slot $(slot_name "${current_slot}"). Requested image: ${pending_build} at ${requested_at}."
fi

printf '%s\n' "${result}" > "${state_dir}/last-result"
printf '%s\n' "${message}" > "${state_dir}/last-message"
printf '%s\n' "${message}" > "${message_file}"

rm -f "${state_dir}/pending-slot" "${state_dir}/pending-build" "${state_dir}/pending-requested-at"

if command -v logger >/dev/null 2>&1; then
    logger -t physical-ai-ab-update "${message}"
fi
