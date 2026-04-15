# SPDX-License-Identifier: MIT
#
# systemd-conf bbappend — enforce read-only rootfs at the systemd mount level
# Installs a drop-in for the root mount unit (-.mount) to set Options=ro.
# Optionally installs an overlayfs-aware drop-in when ROOTFS_MODE = "overlayfs".

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://10-readonly-root.conf"

# Guard: only install the ro drop-in when the build requests it.
# build.sh sets this to "0" for --rootfs rw builds so the board can
# actually boot read-write.  Default is "1" (read-only enforcement).
SYSTEMD_ROOTFS_RO_DROPIN ?= "1"

do_install:append() {
    if [ "${SYSTEMD_ROOTFS_RO_DROPIN}" = "1" ]; then
        # systemd root mount drop-in directory
        install -d ${D}${sysconfdir}/systemd/system/-.mount.d

        # Install the read-only enforcement drop-in
        install -m 0644 ${WORKDIR}/10-readonly-root.conf \
            ${D}${sysconfdir}/systemd/system/-.mount.d/10-readonly-root.conf
    fi
}

FILES:${PN} += "${sysconfdir}/systemd/system/-.mount.d/"
