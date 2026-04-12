# SPDX-License-Identifier: MIT
#
# overlayfs-setup — tmpfs-backed overlayfs on top of a read-only rootfs
#
# When ROOTFS_MODE = "overlayfs" is set (via build.sh), this recipe is
# IMAGE_INSTALL:appended. It installs a oneshot systemd service that:
#   1. Mounts a tmpfs for the overlay upper/work dirs
#   2. Constructs an overlayfs combining ro-root (lower) + tmpfs (upper)
#   3. Pivots into the overlay mount
#
# Data in the writable layer is VOLATILE — lost on every reboot.
# This is intentional for ephemeral node workloads.

SUMMARY = "tmpfs-backed overlayfs pivot for read-only rootfs"
DESCRIPTION = "Early-boot systemd service that layers a writable tmpfs \
overlay on top of a dm-verity read-only root filesystem. All writes are \
volatile and discarded on reboot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

RDEPENDS:${PN} = "util-linux-mount"

SRC_URI = "file://overlayfs-rootfs.service"

inherit systemd

SYSTEMD_SERVICE:${PN} = "overlayfs-rootfs.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/overlayfs-rootfs.service \
        ${D}${systemd_system_unitdir}/overlayfs-rootfs.service

    # Create overlay mount points in the rootfs
    install -d ${D}/overlay
    install -d ${D}/overlay/upper
    install -d ${D}/overlay/work
    install -d ${D}/overlay/merged
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/overlayfs-rootfs.service \
    /overlay \
    /overlay/upper \
    /overlay/work \
    /overlay/merged \
"
