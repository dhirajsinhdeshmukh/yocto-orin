# OTA Update Guide — NVIDIA Jetson Orin Nano

This guide explains how to add over-the-air (OTA) update capability to the
Jetson Orin Nano BSP. It covers the A/B boot slot architecture already present
in the hardware, a comparison of OTA frameworks, and step-by-step integration
with **RAUC** — the recommended choice for this BSP.

---

## Table of Contents

1. [Current A/B Readiness](#1-current-ab-readiness)
2. [OTA Framework Comparison](#2-ota-framework-comparison)
3. [RAUC Architecture Overview](#3-rauc-architecture-overview)
4. [Add RAUC to the BSP](#4-add-rauc-to-the-bsp)
5. [Bundle Creation](#5-bundle-creation)
6. [Deploying an Update](#6-deploying-an-update)
7. [dm-verity + OTA Workflow](#7-dm-verity--ota-workflow)
8. [Rollback Behavior](#8-rollback-behavior)
9. [RAUC + Mender Comparison (extended)](#9-rauc--mender-comparison-extended)
10. [Testing OTA in QEMU](#10-testing-ota-in-qemu)
11. [Reference](#11-reference)

---

## 1. Current A/B Readiness

The BSP already has the hardware and partition infrastructure for A/B OTA:

| Component | Status | Notes |
|---|---|---|
| A/B QSPI boot partitions | **Present** | MB1, MB2, UEFI, BCT all have A/B slots in QSPI |
| A/B rootfs partitions | **Present** | `APP` / `APP_b` on NVMe (28 GiB each) |
| dm-verity | **Present** | RSA-3K signed; must be re-signed per slot per update |
| read-only rootfs | **Present** | systemd-enforced; overlayfs handle writes |
| A/B boot slot switching | **Missing** | Needs RAUC (or equivalent) + UEFI integration |
| OTA bundle infrastructure | **Missing** | Needs RAUC server/client |

> **Short version:** The partitions are ready. You need a userspace update agent
> (RAUC) and a bundle server (HTTP / hawkBit) to tie it together.

---

## 2. OTA Framework Comparison

| | **RAUC** | **Mender** | **swupdate** |
|---|---|---|---|
| License | LGPL-2.1 | Apache 2.0 (client) + proprietary server | GPL-2.0 |
| Yocto layer | `meta-rauc` | `meta-mender` | `meta-swupdate` |
| Deployment model | Bundle (tarball signed with X.509) | Artifact (tar+JSON) | SWU (cpio) |
| A/B support | Native, well-tested | Native | Native |
| dm-verity support | Yes — writes hash tree per slot | Partial (needs custom handler) | Yes |
| Server | hawkBit, custom | Mender Server (hosted/self-hosted) | SWUpdate server |
| Maturity on Tegra | Good (used in production Jetson BSPs) | Good | Good |
| Best fit | **This BSP** — RAUC+hawkBit is the standard Yocto OTA stack | Managed-device fleets | Industrial, custom protocols |

**Recommendation: RAUC.** It has the best native dm-verity integration in
Yocto, is well-tested on Tegra, and the free `meta-rauc` + `meta-rauc-community`
layers integrate cleanly with this BSP.

---

## 3. RAUC Architecture Overview

```
Host (build machine or CI)
│
│   bundles/update-v1.2.0.raucb  ← signed update bundle
│
▼
Update server (hawkBit / HTTP)
│
▼
Jetson Orin Nano (device)
│
├── rauc daemon  ←─── polls server, downloads bundle, verifies signature
│        │
│        ├── writes rootfs image to inactive slot (APP or APP_b)
│        ├── signs new dm-verity hash tree
│        ├── writes dm-verity hash to inactive hash partition
│        └── marks new slot as "good" in UEFI boot counter
│
├── UEFI boot loader
│        └── on next boot: selects the newly marked slot; decrements try-count
│
└── Linux kernel
         └── mounts dm-verity verified rootfs from new slot
```

On a successful boot, `rauc status mark-active` must be called (typically via a
systemd service) to mark the slot permanently good. If it is never called (e.g.,
kernel panic), the UEFI try-count reaches 0 and the bootloader falls back to the
previous slot.

---

## 4. Add RAUC to the BSP

### 4.1 Add meta-rauc and meta-rauc-community layers

Edit `kas/layers.yml`:

```yaml
repos:
  meta-rauc:
    url: "https://github.com/rauc/meta-rauc.git"
    refspec: "2024.04"   # pin to a release tag or commit SHA
    layers:
      .:

  meta-rauc-community:
    url: "https://github.com/rauc/meta-rauc-community.git"
    refspec: "<commit-sha>"  # always pin to SHA per project conventions
    layers:
      meta-rauc-tegra:       # Tegra-specific RAUC bootloader integration
```

> Always pin to a specific commit SHA or release tag — never a branch name.
> Verify the subdirectory name with `ls <cloned-repo>/` before committing.

### 4.2 Create a RAUC system configuration recipe

Create `meta-physical-ai/recipes-core/rauc/rauc-system.conf`:

```ini
[system]
compatible=jetson-orin-nano-orin
bootloader=uboot
statusfile=/var/lib/rauc/system.conf

[keyring]
path=/etc/rauc/ca.cert.pem

[slot.rootfs.0]
device=/dev/nvme0n1p1
type=ext4
bootname=A

[slot.rootfs.1]
device=/dev/nvme0n1p2
type=ext4
bootname=B
```

Create `meta-physical-ai/recipes-core/rauc/rauc_%.bbappend`:

```bitbake
FILESEXTRAPATHS:prepend := "${THISDIR}:"

SRC_URI:append = " file://rauc-system.conf"

do_install:append() {
    install -d ${D}${sysconfdir}/rauc
    install -m 0644 ${WORKDIR}/rauc-system.conf \
        ${D}${sysconfdir}/rauc/system.conf
}
```

### 4.3 Generate RAUC signing keys

```bash
# Development keys (NOT for production)
mkdir -p keys/rauc
cd keys/rauc

# CA key + cert
openssl req -x509 -newkey rsa:4096 \
    -keyout ca.key.pem -out ca.cert.pem \
    -days 3650 -nodes \
    -subj "/CN=RAUC Dev CA/O=Your Org"

# Signing key + cert signed by CA
openssl req -newkey rsa:4096 \
    -keyout signing.key.pem -out signing.csr.pem \
    -nodes -subj "/CN=RAUC Signing/O=Your Org"

openssl x509 -req -in signing.csr.pem \
    -CA ca.cert.pem -CAkey ca.key.pem \
    -CAcreateserial -out signing.cert.pem -days 3650

cd ../..
```

The `keys/` directory is already in `.gitignore` — these keys will never be
committed. Store them in a secrets manager (Vault, AWS Secrets Manager, etc.)
for production.

### 4.4 Install CA cert into image

```bitbake
# meta-physical-ai/recipes-core/rauc/rauc_%.bbappend (continued)

SRC_URI:append = " file://ca.cert.pem"  # copy from keys/rauc/ during build

do_install:append() {
    install -d ${D}${sysconfdir}/rauc
    install -m 0644 ${WORKDIR}/ca.cert.pem \
        ${D}${sysconfdir}/rauc/ca.cert.pem
}
```

### 4.5 Add RAUC to the image

Edit `kas/image-packages.yml`:

```yaml
local_conf_header:
  image-packages: |
    IMAGE_INSTALL:append = " rauc rauc-hawkbit-updater"
```

### 4.6 Rebuild

```bash
./build.sh --rootfs rw --no-dm-verity   # dev iteration
# or
./build.sh                               # production (dm-verity enabled)
./flash.sh
```

---

## 5. Bundle Creation

A RAUC bundle is a signed tarball (`.raucb`) containing the new rootfs image
plus metadata.

### 5.1 Bundle manifest (`manifest.raucm`)

```ini
[update]
compatible=jetson-orin-nano-orin
version=1.2.0

[bundle]
format=verity

[image.rootfs]
filename=rootfs.ext4
```

The `format=verity` tells RAUC to use the dm-verity bundle format — it writes
the Merkle hash tree alongside the rootfs image and verifies integrity before
slot activation.

### 5.2 Create the bundle

```bash
DEPLOY=build/tmp/deploy/images/jetson-orin-nano-devkit-nvme
VERSION=1.2.0

mkdir -p bundles

# Copy rootfs image
cp "${DEPLOY}/demo-image-base-jetson-orin-nano-devkit-nvme.ext4" \
   bundle-work/rootfs.ext4

# Write manifest
cat > bundle-work/manifest.raucm << EOF
[update]
compatible=jetson-orin-nano-orin
version=${VERSION}

[bundle]
format=verity

[image.rootfs]
filename=rootfs.ext4
EOF

# Sign and create the bundle
rauc bundle \
    --cert keys/rauc/signing.cert.pem \
    --key  keys/rauc/signing.key.pem \
    bundle-work/ \
    bundles/update-${VERSION}.raucb

echo "Created: bundles/update-${VERSION}.raucb"
```

### 5.3 Verify the bundle

```bash
rauc info --keyring keys/rauc/ca.cert.pem bundles/update-${VERSION}.raucb
rauc verify --keyring keys/rauc/ca.cert.pem bundles/update-${VERSION}.raucb
```

---

## 6. Deploying an Update

### 6.1 Manual (development)

Copy the bundle to the device and install:

```bash
# From host:
scp bundles/update-1.2.0.raucb root@192.168.1.42:/tmp/

# On device:
rauc install /tmp/update-1.2.0.raucb

# Check status
rauc status
# === System Info ===
# Compatible:  jetson-orin-nano-orin
# Booted from: rootfs.0 (A)
#
# === Slot States ===
# rootfs.0 (A):  booted   good   /dev/nvme0n1p1
# rootfs.1 (B):  inactive good   /dev/nvme0n1p2

# Reboot to activate
reboot
```

After reboot, the device boots from slot B. Add a systemd service to mark it
good automatically:

```bash
# On device (first boot from new slot):
rauc status mark-active
```

### 6.2 Automated via hawkBit

[hawkBit](https://www.eclipse.org/hawkbit/) is a cloud-based update server for
managing device fleets. `rauc-hawkbit-updater` (already added in step 4.5)
polls hawkBit and installs updates automatically.

Configure `/etc/rauc/hawkbit.conf` on the device:

```ini
[client]
hawkbit_server = https://hawkbit.example.com
ssl = true
ssl_verify = true
tenant_id = DEFAULT
target_name = orin-nano-001
auth_token = <device-auth-token>

bundle_download_location = /tmp/bundle.raucb
```

The updater runs as a systemd service (`rauc-hawkbit-updater.service`) and
handles polling, download, verification, and slot activation automatically.

---

## 7. dm-verity + OTA Workflow

dm-verity ensures the rootfs has not been tampered with. For OTA to work with
dm-verity, the update agent must:

1. Write the new rootfs to the **inactive** NVMe partition
2. Compute a new dm-verity hash tree for the new image
3. Write the hash tree + root hash to the inactive hash partition
4. Encode the root hash in the UEFI boot args for the new slot

RAUC's `format=verity` bundle format automates steps 2-4. It uses `veritysetup`
internally to compute and store the hash tree, and writes the root hash to UEFI
U-Boot/UEFI environment variables.

On next boot, dm-verity is initialized from the stored root hash. If verification
fails (corrupted rootfs), the kernel will panic and the bootloader will retry or
fall back to the previous slot.

### Verify dm-verity on a running system

```bash
# Check status of the active slot
veritysetup status rootfs
# type:     VERITY
# status:   verified
# hash type: sha256
# data block: 4096
# hash size:  32
# ...

# The root hash for the active slot
cat /proc/cmdline | grep -o 'roothash=[^ ]*'
```

---

## 8. Rollback Behavior

RAUC + UEFI maintain a `bootcount` / `try-count` per slot in UEFI environment
variables (stored in `A_BOOTCONFIG` / `B_BOOTCONFIG` QSPI partitions).

```
Install update to slot B
          │
          ▼
Reboot → UEFI sets B.tries = 1, boots B
          │
          ├─ [Success] rauc status mark-active → B.good = 1
          │                                   → stays on B
          │
          └─ [Failure: kernel panic, watchdog]
                    │
                    ▼
              UEFI: B.tries reached 0, falls back to A
              (A.good = 1 from previous install)
```

### Configure watchdog for OTA safety

The board's hardware watchdog must be armed before the update activates, and
reset (pet) only after `rauc status mark-active` succeeds:

```bash
# Enable watchdog (kick interval: 60s)
echo 60 > /dev/watchdog

# In the post-install confirmation service:
rauc status mark-active && echo "V" > /dev/watchdog
```

---

## 9. RAUC + Mender Comparison (extended)

For teams evaluating both options:

| Criterion | RAUC + hawkBit | Mender |
|---|---|---|
| **Cost** | Free (open source) | Free client, paid managed server |
| **Self-hosted server** | hawkBit (Spring Boot, Docker) | Mender Server (complex multi-service) |
| **Yocto integration** | `meta-rauc` (official) | `meta-mender` (official) |
| **dm-verity** | Native `verity` bundle format | Custom handler required |
| **Delta updates** | casync-based deltas (RAUC 1.7+) | Compressed full image |
| **Rollback** | bootcount via UEFI env vars | bootcount via U-Boot env vars |
| **Device grouping** | hawkBit rollout groups | Mender deployment groups |
| **Best for** | Standalone devices, custom infra | Managed fleets, SaaS preferred |

---

## 10. Testing OTA in QEMU

Before flashing to real hardware, you can test the OTA flow in QEMU with an
emulated block device:

```bash
# Create two rootfs images (A and B)
qemu-img create -f raw slot-a.ext4 4G
qemu-img create -f raw slot-b.ext4 4G
mkfs.ext4 slot-a.ext4

# Boot from slot A
qemu-system-aarch64 \
    -M virt -cpu cortex-a57 -m 2048 \
    -drive file=slot-a.ext4,format=raw,id=hda \
    -drive file=slot-b.ext4,format=raw,id=hdb \
    -kernel your-kernel.img \
    -append "root=/dev/vda rw"

# Inside QEMU, install bundle to slot B
rauc install /path/to/update.raucb
reboot
```

> Note: Full Tegra SoC emulation is not available in upstream QEMU. This QEMU
> test validates the RAUC install/rollback logic but not Tegra-specific boot
> firmware behavior.

---

## 11. Reference

| Resource | URL / Path |
|---|---|
| RAUC documentation | https://rauc.readthedocs.io |
| meta-rauc layer | https://github.com/rauc/meta-rauc |
| meta-rauc-community | https://github.com/rauc/meta-rauc-community |
| hawkBit server | https://www.eclipse.org/hawkbit/ |
| rauc-hawkbit-updater | https://github.com/rauc/rauc-hawkbit-updater |
| Tegra UEFI OTA variables | Jetson Linux Developer Guide — OTA section |
| A/B partition layout | `flash-artifacts/.../external-flash.xml.in` (after extraction) |
| dm-verity setup | `kas/local-conf.yml` — `dm-verity:` block |
| RAUC signing keys | `keys/rauc/` (gitignored — generate locally) |
