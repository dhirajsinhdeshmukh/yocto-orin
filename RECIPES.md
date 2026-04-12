# Layer & Recipe Development Guide

How to add custom layers, create recipes, extend existing recipes, and ship
your own code inside the Jetson BSP.

---

## Table of Contents

1. [Layer Concepts](#layer-concepts)
2. [Adding a Remote Community Layer](#adding-a-remote-community-layer)
3. [Adding a Local Repo as a Layer](#adding-a-local-repo-as-a-layer)
4. [Creating a New Recipe](#creating-a-new-recipe)
5. [Recipe Types & Skeletons](#recipe-types--skeletons)
6. [Extending an Existing Recipe (bbappend)](#extending-an-existing-recipe-bbappend)
7. [Patching Upstream Source](#patching-upstream-source)
8. [Custom systemd Service](#custom-systemd-service)
9. [Installing Config Files (read-only rootfs safe)](#installing-config-files-read-only-rootfs-safe)
10. [Native & nativesdk Recipes (host tools)](#native--nativesdk-recipes-host-tools)
11. [Recipe Variables Cheat Sheet](#recipe-variables-cheat-sheet)
12. [Testing & Iterating Locally](#testing--iterating-locally)

---

## Layer Concepts

A Yocto **layer** is a directory that contains:
- `conf/layer.conf` — registers the layer with bitbake
- `recipes-*/` — recipe collections (`.bb` and `.bbappend` files)
- `classes/` — `.bbclass` files (reusable logic)
- `files/` or per-recipe `files/` subdirs — patches, config files, service units

**Layer priority** (set in `layer.conf` via `BBFILE_PRIORITY`) determines which
layer wins when two layers provide the same recipe. Higher number = higher priority.
`meta-physical-ai` uses priority `10`, above most community layers (typically 6–8).

**Scarthgap compatibility** — every layer must declare:
```
LAYERSERIES_COMPAT_<collection> = "scarthgap"
```
CI enforces this for `meta-physical-ai`.

---

## Adding a Remote Community Layer

Edit [kas/layers.yml](kas/layers.yml). **Always pin to a commit SHA.**

### Step 1 — Get the current scarthgap HEAD SHA

```bash
git ls-remote https://git.openembedded.org/meta-openembedded refs/heads/scarthgap | cut -f1
```

### Step 2 — Add the repo block

```yaml
# filepath: kas/layers.yml
repos:
  # ...existing repos...

  meta-openembedded:
    url: "https://git.openembedded.org/meta-openembedded"
    refspec: "7cb2f8d3a45e1b2c9f0a1234567890abcdef1234"   # replace with actual SHA
    layers:
      meta-oe:           # general utilities, libs, tools
      meta-python:       # python3-* packages
      meta-networking:   # network tools (iperf, nmap, etc.)
      meta-multimedia:   # GStreamer plugins, media codecs
```

### Step 3 — Update layer dependency in meta-physical-ai

If your recipes in `meta-physical-ai` use anything from the new layer:

```
# filepath: meta-physical-ai/conf/layer.conf
LAYERDEPENDS_physical-ai = "core tegra openembedded-layer"
#                                         ^^ collection name from new layer.conf
```

### Step 4 — Validate

```bash
python3 -c "import yaml; yaml.safe_load(open('kas/layers.yml'))" && echo "YAML OK"
kas shell kas-project.yml -c "bitbake-layers show-layers"
```

---

## Adding a Local Repo as a Layer

Use this when you have a layer under active development — a second git repo on
your machine (not yet published), or a monorepo subtree.

### Option A: Sibling directory (separate git repo)

```
/home/drex/src/
├── yocto_orin/          ← this repo (kas-project.yml here)
└── meta-my-app/         ← your other layer
    ├── conf/layer.conf
    └── recipes-myapp/
```

In `kas/layers.yml`:

```yaml
# filepath: kas/layers.yml
repos:
  meta-my-app:
    path: ../meta-my-app   # relative to kas-project.yml — NO url: key
    layers:
      meta-my-app:
```

> `path:` is resolved relative to the directory containing `kas-project.yml`.
> No `url:` = no fetching; kas just adds it to `BBLAYERS` as-is.

### Option B: Subdirectory inside this repo

```
yocto_orin/
├── kas-project.yml
└── layers/
    └── meta-my-app/
        └── conf/layer.conf
```

```yaml
# filepath: kas/layers.yml
repos:
  meta-my-app:
    path: layers/meta-my-app
    layers:
      meta-my-app:
```

### Required `conf/layer.conf` for any local layer

```
# filepath: meta-my-app/conf/layer.conf
BBPATH .= ":${LAYERDIR}"

BBFILES += " \
    ${LAYERDIR}/recipes-*/*/*.bb \
    ${LAYERDIR}/recipes-*/*/*.bbappend \
"

BBFILE_COLLECTIONS += "my-app"
BBFILE_PATTERN_my-app = "^${LAYERDIR}/"
BBFILE_PRIORITY_my-app = "10"

LAYERDEPENDS_my-app = "core tegra"
LAYERSERIES_COMPAT_my-app = "scarthgap"
```

---

## Creating a New Recipe

Recipes live in `meta-physical-ai/recipes-<category>/<name>/`.

**Naming convention:**
- `<name>_<version>.bb` — versioned (e.g. `my-app_1.0.bb`)
- Multiple versions can coexist; `PREFERRED_VERSION` selects between them

### Minimal recipe skeleton

```bitbake
# filepath: meta-physical-ai/recipes-myapp/my-app/my-app_1.0.bb

# SPDX-License-Identifier: MIT

SUMMARY = "Short one-line description"
DESCRIPTION = "Longer description of what this does on the Jetson."
HOMEPAGE = "https://github.com/my-org/my-app"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=<md5sum-of-license-file>"

# --- Source ---
SRC_URI = "git://github.com/my-org/my-app.git;protocol=https;branch=main"
SRCREV = "abcdef1234567890abcdef1234567890abcdef12"  # pinned commit SHA

S = "${WORKDIR}/git"

# --- Build ---
inherit cmake

# cmake options
EXTRA_OECMAKE = "-DBUILD_TESTS=OFF -DENABLE_CUDA=ON"

# --- Runtime dependencies (installed on Jetson) ---
RDEPENDS:${PN} = "python3 libssl"

# --- Install ---
do_install:append() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/my-app ${D}${bindir}/my-app
}

FILES:${PN} += "${bindir}/my-app"
```

### Fetching from different sources

```bitbake
# Tarball from URL
SRC_URI = "https://example.com/releases/my-app-${PV}.tar.gz"
SRC_URI[sha256sum] = "abc123..."   # get with: sha256sum my-app-1.0.tar.gz

# Local file in recipe's files/ dir
SRC_URI = "file://my-config.conf \
           file://my-app.service"

# Multiple sources
SRC_URI = "git://github.com/org/repo.git;protocol=https;branch=main \
           file://0001-fix-cmakelists.patch \
           file://my-app.service"
SRCREV = "<sha>"
```

### Build system variants

```bitbake
inherit cmake        # CMake
inherit autotools    # autoconf/automake (./configure && make)
inherit meson        # Meson build system
inherit python3-dir  # pure Python package (no build step)
inherit setuptools3  # Python setuptools
```

---

## Recipe Types & Skeletons

### `cmake` application

```bitbake
SUMMARY = "My CMake app"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=..."

SRC_URI = "git://github.com/org/repo.git;protocol=https;branch=main"
SRCREV = "<sha>"
S = "${WORKDIR}/git"

inherit cmake

EXTRA_OECMAKE = "-DBUILD_EXAMPLES=OFF"

RDEPENDS:${PN} = "libstdc++"
```

### `autotools` library

```bitbake
SUMMARY = "My autotools lib"
LICENSE = "LGPL-2.1-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=..."

SRC_URI = "https://example.com/mylib-${PV}.tar.gz"
SRC_URI[sha256sum] = "..."

inherit autotools pkgconfig

# Extra ./configure arguments
EXTRA_OECONF = "--disable-tests --enable-shared"

# Split dev headers into a separate -dev package
PACKAGES =+ "${PN}-dev"
FILES:${PN}-dev = "${includedir} ${libdir}/*.so ${libdir}/pkgconfig"
```

### Python package (from PyPI)

```bitbake
SUMMARY = "My Python library"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=..."

SRC_URI[sha256sum] = "..."

inherit pypi python_setuptools_build_meta

PYPI_PACKAGE = "my-lib"

RDEPENDS:${PN} = "python3-numpy"
```

### Shell script / plain file deployment

```bitbake
SUMMARY = "Deploy config files and scripts to rootfs"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://my-script.sh \
           file://my-config.json"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/my-script.sh ${D}${bindir}/my-script

    install -d ${D}${sysconfdir}/my-app
    install -m 0644 ${WORKDIR}/my-config.json ${D}${sysconfdir}/my-app/config.json
}

FILES:${PN} = "${bindir}/my-script ${sysconfdir}/my-app/"
```

---

## Extending an Existing Recipe (bbappend)

`.bbappend` files modify a recipe **without copying it**. They are applied on top
of the original `.bb` from whichever layer it lives in.

**Filename must match the recipe:**
- `<name>_<version>.bbappend` — matches exactly
- `<name>_%.bbappend` — matches any version (use this for community recipes)

### Common patterns

#### Add extra source files

```bitbake
# filepath: meta-physical-ai/recipes-core/systemd/systemd_%.bbappend

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://my-extra.conf"

do_install:append() {
    install -d ${D}${sysconfdir}/systemd/journald.conf.d/
    install -m 0644 ${WORKDIR}/my-extra.conf \
        ${D}${sysconfdir}/systemd/journald.conf.d/my-extra.conf
}

FILES:${PN}:append = " ${sysconfdir}/systemd/journald.conf.d/"
```

#### Change a configure option

```bitbake
# filepath: meta-physical-ai/recipes-connectivity/openssh/openssh_%.bbappend

# Disable X11 forwarding in our builds
EXTRA_OECONF:remove = "--with-xauth"
EXTRA_OECONF:append = " --without-x"
```

#### Add a dependency

```bitbake
# filepath: meta-physical-ai/recipes-core/images/demo-image-base.bbappend

IMAGE_INSTALL:append = " my-app htop"
```

#### Override a variable only for your MACHINE

```bitbake
EXTRA_OECMAKE:jetson-orin-nano-devkit-nvme = "-DCUDA_ARCH=87"
```

---

## Patching Upstream Source

Patches are `.patch` files placed in the recipe's `files/` directory and listed
in `SRC_URI`. They are applied by `do_patch` in order.

### Generate a patch from git

```bash
# Make your change in the recipe's devshell
kas build kas-project.yml --cmd "bitbake <recipe> -c devshell"
# (inside devshell)
git diff > /tmp/0001-my-fix.patch
exit

# Copy the patch into the recipe files dir
cp /tmp/0001-my-fix.patch \
   meta-physical-ai/recipes-<cat>/<recipe>/files/0001-my-fix.patch
```

### Reference the patch in the recipe

```bitbake
SRC_URI:append = " file://0001-my-fix.patch"
# Patches are applied automatically by do_patch in numeric order
```

### Patch format

Use standard `git format-patch` format:
```
From abc123 Mon Sep 17 00:00:00 2001
Subject: [PATCH] Fix CMakeLists CUDA arch detection

--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -42,1 +42,1 @@
-set(CUDA_ARCH "all")
+set(CUDA_ARCH "87")   # Jetson Orin: sm_87
```

---

## Custom systemd Service

Full example — a daemon that runs on the Jetson.

### File layout

```
meta-physical-ai/
└── recipes-apps/
    └── my-daemon/
        ├── my-daemon_1.0.bb
        └── files/
            ├── my-daemon.sh          ← the actual daemon script/binary
            └── my-daemon.service     ← systemd unit
```

### Recipe

```bitbake
# filepath: meta-physical-ai/recipes-apps/my-daemon/my-daemon_1.0.bb

# SPDX-License-Identifier: MIT
SUMMARY = "My application daemon"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://my-daemon.sh \
           file://my-daemon.service"

inherit systemd

SYSTEMD_SERVICE:${PN}      = "my-daemon.service"
SYSTEMD_AUTO_ENABLE:${PN}  = "enable"

RDEPENDS:${PN} = "bash"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/my-daemon.sh ${D}${bindir}/my-daemon

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/my-daemon.service \
        ${D}${systemd_system_unitdir}/my-daemon.service
}

FILES:${PN} = "${bindir}/my-daemon ${systemd_system_unitdir}/my-daemon.service"
```

### systemd unit file

```ini
# filepath: meta-physical-ai/recipes-apps/my-daemon/files/my-daemon.service

[Unit]
Description=My Application Daemon
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/my-daemon
Restart=on-failure
RestartSec=5

# Read-only rootfs safe — write to /run (tmpfs)
RuntimeDirectory=my-daemon
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
```

### Wire into the image

```yaml
# filepath: kas/image-packages.yml
local_conf_header:
  image-base: |
    IMAGE_INSTALL:append = " my-daemon"
```

---

## Installing Config Files (read-only rootfs safe)

On a read-only rootfs, config files at `/etc/` cannot be written at runtime.
Use these patterns:

### Static config (never changes at runtime)

Install directly to `/etc/` — works on read-only rootfs:

```bitbake
do_install() {
    install -d ${D}${sysconfdir}/my-app
    install -m 0644 ${WORKDIR}/my-config.json ${D}${sysconfdir}/my-app/config.json
}
```

### Mutable config (needs runtime writes)

Use `tmpfiles.d(5)` to create a writable copy in `/run` at boot:

```bitbake
SRC_URI += "file://my-app-tmpfiles.conf"

do_install:append() {
    install -d ${D}${libdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/my-app-tmpfiles.conf \
        ${D}${libdir}/tmpfiles.d/my-app.conf
}
FILES:${PN} += "${libdir}/tmpfiles.d/my-app.conf"
```

```
# filepath: files/my-app-tmpfiles.conf
# Type  Path                    Mode  User  Group  Age  Argument
d       /run/my-app             0755  root  root   -    -
C       /run/my-app/config.json 0644  root  root   -    /etc/my-app/config.json
#                                                       ^^ copies from /etc at boot
```

The `C` directive copies the file from `/etc` to `/run` on first boot — the app
then reads/writes `/run/my-app/config.json` (tmpfs, writable). Original in `/etc`
is the pristine read-only template.

---

## Native & nativesdk Recipes (host tools)

Sometimes you need a tool to run **during the build** (not on the Jetson) or
inside the **SDK environment** on the developer's machine.

### `native` — runs during the build on the build host

```bitbake
# filepath: meta-physical-ai/recipes-devtools/my-codegen/my-codegen_1.0.bb

SUMMARY = "Code generator used during build"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=..."

SRC_URI = "file://my-codegen.py"

inherit native    # ← this is the key

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/my-codegen.py ${D}${bindir}/my-codegen
}
```

Use in another recipe's `DEPENDS`:
```bitbake
DEPENDS = "my-codegen-native"
```

### `nativesdk` — runs inside the SDK environment

```bitbake
# filepath: meta-physical-ai/recipes-devtools/my-sdk-tool/my-sdk-tool_1.0.bb

SUMMARY = "Tool available inside the Yocto SDK"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=..."

SRC_URI = "file://my-sdk-tool.sh"

inherit nativesdk   # ← this is the key

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/my-sdk-tool.sh ${D}${bindir}/my-sdk-tool
}
```

Then add to `kas/sdk.yml`:
```yaml
sdk-host: |
  TOOLCHAIN_HOST_TASK:append = " nativesdk-my-sdk-tool"
```

---

## Recipe Variables Cheat Sheet

| Variable | Scarthgap syntax | Purpose |
|---|---|---|
| `SUMMARY` | `SUMMARY = "..."` | One-line description |
| `LICENSE` | `LICENSE = "MIT"` | SPDX identifier |
| `LIC_FILES_CHKSUM` | `LIC_FILES_CHKSUM = "file://LICENSE;md5=..."` | License file verification |
| `SRC_URI` | `SRC_URI = "git://...;branch=main"` | Source location |
| `SRCREV` | `SRCREV = "<sha>"` | Git commit to fetch |
| `S` | `S = "${WORKDIR}/git"` | Source extraction dir |
| `B` | `B = "${WORKDIR}/build"` | Build dir (cmake out-of-tree) |
| `D` | `D = "${WORKDIR}/image"` | Staging install dir |
| `DEPENDS` | `DEPENDS = "openssl"` | Build-time deps (dev packages) |
| `RDEPENDS:${PN}` | `RDEPENDS:${PN} = "python3"` | Runtime deps (on Jetson) |
| `PACKAGES` | `PACKAGES = "${PN} ${PN}-dev ${PN}-doc"` | Sub-packages |
| `FILES:${PN}` | `FILES:${PN} = "${bindir}/..."` | Files in main package |
| `EXTRA_OECMAKE` | `EXTRA_OECMAKE = "-DFOO=ON"` | cmake arguments |
| `EXTRA_OECONF` | `EXTRA_OECONF = "--disable-x"` | autotools arguments |
| `EXTRA_OEMAKE` | `EXTRA_OEMAKE = "ARCH=arm64"` | make arguments |
| `FILESEXTRAPATHS` | `FILESEXTRAPATHS:prepend := "${THISDIR}/files:"` | Extra search paths for SRC_URI file:// |
| `SYSTEMD_SERVICE:${PN}` | `SYSTEMD_SERVICE:${PN} = "foo.service"` | systemd unit name |
| `COMPATIBLE_MACHINE` | `COMPATIBLE_MACHINE = "jetson.*"` | Restrict recipe to specific machines |

**Scarthgap operator rules (`:` not `_`):**
```bitbake
# CORRECT
RDEPENDS:${PN} = "..."
FILES:${PN}-dev = "..."
do_install:append() { ... }
EXTRA_OECMAKE:jetson-orin-nano-devkit-nvme = "..."
SYSTEMD_SERVICE:${PN} = "..."

# WRONG (Dunfell/old syntax — will silently fail or warn in scarthgap)
RDEPENDS_${PN} = "..."          # ❌
do_install_append() { ... }     # ❌
```

---

## Testing & Iterating Locally

### Rapid rebuild cycle

```bash
# 1. Edit recipe or source file
# 2. Bump bitbake task explicitly (skip full dependency check):
kas build kas-project.yml --cmd "bitbake <recipe> -c compile -f && bitbake <recipe> -c install -f"

# 3. Re-assemble image (fast — just re-packs rootfs)
kas build kas-project.yml --cmd "bitbake demo-image-base -c rootfs -f"
```

### devshell — work inside the recipe environment

```bash
kas build kas-project.yml --cmd "bitbake <recipe> -c devshell"
# Inside devshell:
cmake ${OECMAKE_SOURCEPATH} ${EXTRA_OECMAKE}   # test cmake config
make -j4                                         # test compile
exit
```

### wic image inspection (rootfs contents without booting)

```bash
# Mount the rootfs image locally
ROOTFS=build/tmp/deploy/images/jetson-orin-nano-devkit-nvme/demo-image-base-*.rootfs.ext4
mkdir -p /tmp/rootfs-mount
sudo mount -o loop,ro "$ROOTFS" /tmp/rootfs-mount

# Inspect
ls /tmp/rootfs-mount/usr/bin/my-app
cat /tmp/rootfs-mount/etc/my-app/config.json

sudo umount /tmp/rootfs-mount
```

### Check install paths match expected

```bash
# List all files provided by a recipe
kas build kas-project.yml --cmd "oe-pkgdata-util list-pkg-files <recipe>"

# Check which package owns a file
kas build kas-project.yml --cmd "oe-pkgdata-util find-path /usr/bin/my-app"
```
