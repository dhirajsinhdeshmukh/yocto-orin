SUMMARY = "Physical AI storage initialization"
DESCRIPTION = "First-boot rootfs resize and persistent data mount for NVMe deployments."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://physical-ai-firstboot-storage.sh \
    file://physical-ai-rootfs-grow.service \
"

S = "${WORKDIR}"

inherit systemd

RDEPENDS:${PN} = " \
    e2fsprogs-resize2fs \
    util-linux-findmnt \
"

SYSTEMD_SERVICE:${PN} = "physical-ai-rootfs-grow.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
FILES:${PN} += " \
    /data \
    ${sbindir}/physical-ai-firstboot-storage \
    ${systemd_system_unitdir}/physical-ai-rootfs-grow.service \
    ${localstatedir}/lib/physical-ai \
"

do_install() {
    install -d "${D}${sbindir}"
    install -m 0755 "${WORKDIR}/physical-ai-firstboot-storage.sh" "${D}${sbindir}/physical-ai-firstboot-storage"

    install -d "${D}${systemd_system_unitdir}"
    install -m 0644 "${WORKDIR}/physical-ai-rootfs-grow.service" "${D}${systemd_system_unitdir}/physical-ai-rootfs-grow.service"

    install -d "${D}/data" "${D}${localstatedir}/lib/physical-ai"
}

pkg_postinst_ontarget:${PN}() {
#!/bin/sh
mkdir -p /data
entry='/dev/disk/by-partlabel/UDA /data ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2'
grep -Fqx "$entry" /etc/fstab || printf '%s\n' "$entry" >> /etc/fstab
}
