#!/bin/sh

message_file="/var/lib/physical-ai/ab-update-message"

if [ -n "${PS1:-}" ] && [ -r "${message_file}" ]; then
    message="$(cat "${message_file}" 2>/dev/null || true)"
    if [ -n "${message}" ]; then
        printf '\n[physical-ai] %s\n\n' "${message}"
    fi
fi
