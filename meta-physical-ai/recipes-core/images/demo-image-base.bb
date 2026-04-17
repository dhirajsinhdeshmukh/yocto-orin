SUMMARY = "Physical AI — Jetson Orin Nano base image"
DESCRIPTION = "Minimal hardened base image for Jetson Orin Nano. \
Supports ro/rw/overlayfs rootfs modes controlled via build.sh."
LICENSE = "MIT"

inherit core-image

# ── Base image features ───────────────────────────────────────────────────────
# splash          — boot splash (Plymouth or framebuffer)
# ssh-server-openssh — OpenSSH for dev access; remove for production
IMAGE_FEATURES += " \
    ssh-server-openssh \
"

# ── Core package set ──────────────────────────────────────────────────────────
# Packages here are IN ADDITION to IMAGE_INSTALL:append in kas/image-packages.yml
IMAGE_INSTALL += " \
    packagegroup-core-boot \
    kernel-modules \
    physical-ai-storage \
    tegra-firmware \
    tegra-nvpmodel \
    util-linux \
    procps \
"
