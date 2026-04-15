#!/bin/sh

set -eu

stamp="/var/lib/physical-ai/rootfs-resized.stamp"

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
touch "${stamp}"
