SUMMARY = "Physical AI storage initialization"
DESCRIPTION = "First-boot rootfs resize and persistent data mount for NVMe deployments."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://physical-ai-firstboot-storage.sh \
    file://physical-ai-rootfs-grow.service \
    file://physical-ai-ab-status-check.sh \
    file://physical-ai-ab-status.service \
    file://physical-ai-ab-update-notify.sh \
"

S = "${WORKDIR}"

inherit systemd

RDEPENDS:${PN} = " \
    e2fsprogs-mke2fs \
    e2fsprogs-resize2fs \
    tegra-redundant-boot \
    util-linux-blkid \
    util-linux-findmnt \
    util-linux-mount \
"

SYSTEMD_SERVICE:${PN} = "physical-ai-rootfs-grow.service physical-ai-ab-status.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
FILES:${PN} += " \
    /data \
    ${sysconfdir}/profile.d/physical-ai-ab-update-notify.sh \
    ${sbindir}/physical-ai-ab-status-check \
    ${sbindir}/physical-ai-firstboot-storage \
    ${systemd_system_unitdir}/physical-ai-ab-status.service \
    ${systemd_system_unitdir}/physical-ai-rootfs-grow.service \
    ${localstatedir}/lib/physical-ai \
"

do_install() {
    install -d "${D}${sbindir}"
    install -m 0755 "${WORKDIR}/physical-ai-firstboot-storage.sh" "${D}${sbindir}/physical-ai-firstboot-storage"
    install -m 0755 "${WORKDIR}/physical-ai-ab-status-check.sh" "${D}${sbindir}/physical-ai-ab-status-check"

    install -d "${D}${systemd_system_unitdir}"
    install -m 0644 "${WORKDIR}/physical-ai-rootfs-grow.service" "${D}${systemd_system_unitdir}/physical-ai-rootfs-grow.service"
    install -m 0644 "${WORKDIR}/physical-ai-ab-status.service" "${D}${systemd_system_unitdir}/physical-ai-ab-status.service"

    install -d "${D}${sysconfdir}/profile.d"
    install -m 0755 "${WORKDIR}/physical-ai-ab-update-notify.sh" "${D}${sysconfdir}/profile.d/physical-ai-ab-update-notify.sh"

    install -d "${D}/data" "${D}${localstatedir}/lib/physical-ai"
}

pkg_postinst_ontarget:${PN}() {
#!/bin/sh
mkdir -p /data
entry='/dev/disk/by-partlabel/UDA /data ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2'
grep -Fqx "$entry" /etc/fstab || printf '%s\n' "$entry" >> /etc/fstab
}
