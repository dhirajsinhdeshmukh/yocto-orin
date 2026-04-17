#!/bin/sh

set -eu

stamp="/var/lib/physical-ai/rootfs-resized.stamp"
data_part="/dev/disk/by-partlabel/UDA"
data_mount="/data"
data_fstab_entry='/dev/disk/by-partlabel/UDA /data ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2'

if [ -e "${stamp}" ]; then
    exit 0
fi

rootdev="$(findmnt -n -o SOURCE / || true)"
case "${rootdev}" in
    /dev/*) ;;
    *)
        exit 0
        ;;
esac

mkdir -p /var/lib/physical-ai

resize2fs "${rootdev}"

if [ -b "${data_part}" ]; then
    mkdir -p "${data_mount}"

    if [ -z "$(blkid -p -s TYPE -o value "${data_part}" 2>/dev/null)" ]; then
        mkfs.ext4 -F "${data_part}"
    fi

    grep -Fqx "${data_fstab_entry}" /etc/fstab || printf '%s\n' "${data_fstab_entry}" >> /etc/fstab

    if ! findmnt -n "${data_mount}" >/dev/null 2>&1; then
        mount "${data_mount}" || true
    fi
fi

touch "${stamp}"
