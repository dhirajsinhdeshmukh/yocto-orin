# New Yocto Recipe Prompt
# Usage: Open Copilot Chat → type /new-recipe

You are helping create a new Yocto recipe inside the `meta-physical-ai` custom layer.

## Context
- Custom layer: `meta-physical-ai/`
- Yocto release: scarthgap (5.0) — use `:` variable operators, not `_`
- Init system: systemd
- Reference guide: `docs/RECIPES.md`

## Recipe Skeleton (for a systemd service)

```bitbake
# SPDX-License-Identifier: MIT
SUMMARY = "<one-line description>"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://<name>.service"

inherit systemd

SYSTEMD_SERVICE:${PN} = "<name>.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/<name>.service \
        ${D}${systemd_system_unitdir}/<name>.service
}

FILES:${PN} += "${systemd_system_unitdir}/<name>.service"
```

## Task
1. Create `meta-physical-ai/recipes-<category>/<name>/<name>_<version>.bb`
2. Create supporting files under `meta-physical-ai/recipes-<category>/<name>/files/`
3. Add `IMAGE_INSTALL:append = " <name>"` to the appropriate section
   in `kas/image-packages.yml`

## Rules
- Always use `RDEPENDS:${PN}` not `RDEPENDS_${PN}`
- Always use `FILES:${PN}` not `FILES_${PN}`
- For services, always `inherit systemd` — never install directly to `/etc/init.d/`
- For read-only rootfs compatibility: config files that need to be writable at
  runtime should use tmpfiles.d(5) to create them in `/run` or `/var`

## Output
Return the complete `.bb` file, any supporting files, and the `image-packages.yml` diff.
