# SPDX-License-Identifier: MIT
#
# systemd-conf bbappend — enforce read-only rootfs at the systemd mount level
# Installs a drop-in for the root mount unit (-.mount) to set Options=ro.
# Optionally installs an overlayfs-aware drop-in when ROOTFS_MODE = "overlayfs".

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://10-readonly-root.conf"

do_install:append() {
    # systemd root mount drop-in directory
    install -d ${D}${sysconfdir}/systemd/system/-.mount.d

    # Always install the read-only enforcement drop-in
    install -m 0644 ${WORKDIR}/10-readonly-root.conf \
        ${D}${sysconfdir}/systemd/system/-.mount.d/10-readonly-root.conf
}

FILES:${PN} += "${sysconfdir}/systemd/system/-.mount.d/"
