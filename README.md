# Hardened Jetson Orin Nano BSP — Yocto / kas

Production-grade Yocto BSP for the **NVIDIA Jetson Orin Nano** targeting NVMe boot with:

- **dm-verity** signed rootfs (RSA-3K)
- **Read-only rootfs** (systemd-enforced)
- **Optional overlayfs** (tmpfs-backed volatile writable layer)
- **Cross-compilation SDK** packaged as a Docker container

| Component | Version / Branch | Pinned |
|---|---|---|
| Poky (OE-Core) | scarthgap (5.0) | `8643f911` |
| meta-tegra (BSP) | scarthgap | `891fc9e6` |
| meta-openembedded | scarthgap | `1ad0d777` |
| meta-security | scarthgap | `b13f1705` |
| meta-physical-ai | local | — |


---

## Overview: Brand-New Board to SSH Access

This custom Orin distro is built for Jetson Orin Nano NVMe boot with a hardened
rootfs: dm-verity signed, systemd-enforced read-only mounts, and optional
overlayfs for a volatile writable layer. If you have a brand-new board or a
freshly erased system, follow this exact flow to get from power-off to a working
SSH login.

### End-to-End Flow

1. Power off the Jetson.
2. Put it into recovery mode by shorting **FC_REC** to **GND** on the recovery header.
3. Connect **USB-C** to the Jetson and **USB-A** to the host laptop.
4. Power on the board.
5. Verify recovery mode on the host with `lsusb`.
6. Build a writable bring-up image.
7. Flash the board.
8. Let the board boot normally.
9. Find its IP address with `nmap`.
10. Log in with SSH.

### Commands

```bash
# 1. Verify the Jetson is in recovery mode
lsusb | grep -i nvidia

# Expected recovery-mode device
# Bus 00X Device 0XX: ID 0955:7523 NVIDIA Corp. APX

# 2. Build a writable bring-up image for first boot
./build.sh --rootfs rw --no-dm-verity

# 3. Flash the board
./flash.sh

# 4. After the board boots, discover its IP on the local network
nmap -sn 192.168.1.0/24

# 5. Connect over SSH
ssh root@<jetson-ip>
```

## Prerequisites

### Host System

Ubuntu 22.04 LTS (recommended). Install required packages:

```bash
sudo apt-get update
sudo apt-get install -y gawk wget git diffstat unzip texinfo gcc g++ \
    build-essential chrpath socat cpio python3 python3-pip python3-pexpect \
    xz-utils debianutils iputils-ping libsdl1.2-dev xterm python3-git \
    python3-jinja2 python3-subunit python3-setuptools mesa-common-dev \
    zstd liblz4-tool lz4 file locales ca-certificates \
    device-tree-compiler usbutils udisks2
```

### Disk Space

Minimum **100 GB** free. A full build with SDK generation requires ~150 GB.

### Install kas

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

`build.sh` activates `.venv` automatically when `kas` is not already on `PATH`.

Verify:

```bash
kas --version
```

---

## Quick Start

### 1. Generate DM-Verity Signing Keys

Keys **must** exist before the build. See [DM-Verity Signing](#dm-verity-signing-rsa-3k) below.

### 2. Build

```bash
# Bring-up build — writable rootfs, persistent post-deploy config
./build.sh --rootfs rw --no-dm-verity

# Production build — read-only rootfs, dm-verity enabled, 80% of cores
./build.sh

# Explicit machine override
./build.sh --machine jetson-orin-nano-devkit-nvme --rootfs rw --no-dm-verity

# OverlayFS mode — read-only root + volatile writable tmpfs layer
./build.sh --rootfs overlayfs --dm-verity

# Pin to specific CPU cores
./build.sh --cpu-affinity 0-7 --cores 8
```

Or use kas directly:

```bash
kas build kas-project.yml
```

### 3. Flash

See [Flashing](#flashing) below.

---

## Build Script Reference

```
./build.sh [OPTIONS] [-- KAS_BUILD_ARGS [-- BITBAKE_ARGS]]

Options:
  -c, --cores N            BB_NUMBER_THREADS + PARALLEL_MAKE (default: 80% of nproc)
  -a, --cpu-affinity MASK  taskset CPU mask (e.g., 0-7 or 0,2,4,6)
  -m, --machine MACHINE    Override Yocto MACHINE (default: from kas-project.yml)
  -r, --rootfs MODE        ro | rw | overlayfs  (default: ro)
  -d, --dm-verity          Enable dm-verity signing (default)
      --no-dm-verity       Disable dm-verity
  -t, --target IMAGE       Override bitbake target
  -h, --help               Show help
```

Pass extra `kas build` arguments after the first `--`, and raw BitBake arguments
after a second `--`, for example:

```bash
./build.sh -- --target demo-image-base -c populate_sdk
./build.sh -- --target demo-image-base -c rootfs -- -f
```

The script generates a temporary kas override YAML inside `${SCRIPT_DIR}/tmp/` (gitignored),
merged with `kas-project.yml` at build time via kas file concatenation (`:`). The override file
is deleted on exit. kas 5.2+ requires both files to live inside the same git repo—this is why
the override is written under the repo tree, not to system `/tmp`.

### Rootfs Modes

| Mode | `--rootfs` | Description | Production? |
|---|---|---|---|
| **Read-only** | `ro` | Root filesystem is immutable. Enforced at kernel + systemd level. | Yes |
| **OverlayFS** | `overlayfs` | Read-only root + tmpfs-backed writable overlay. Writes are **volatile** (lost on reboot). | Field debug |
| **Read-write** | `rw` | Standard writable rootfs. No integrity protection. | Dev only |

### CPU Control

Two independent mechanisms:

- **`--cores N`** — Sets `BB_NUMBER_THREADS` and `PARALLEL_MAKE` inside bitbake. Controls recipe-level parallelism.
- **`--cpu-affinity MASK`** — Wraps the entire build in `taskset -c MASK`. Pins the process tree to specific cores at the OS level.

Use both together for maximum control:

```bash
# Use cores 0-7 only, 8 threads
./build.sh --cpu-affinity 0-7 --cores 8
```

---

## DM-Verity Signing (RSA-3K)

dm-verity requires an RSA key pair to sign the Merkle tree hash. The build expects keys at:

```
keys/dm-verity/rsa3k-key.pem    # Private key
keys/dm-verity/rsa3k-cert.pem   # Self-signed X.509 certificate
```

### Generate Keys

```bash
mkdir -p keys/dm-verity

# Generate RSA-3072 private key
openssl genpkey \
    -algorithm RSA \
    -pkeyopt rsa_keygen_bits:3072 \
    -out keys/dm-verity/rsa3k-key.pem

# Generate self-signed certificate (10-year validity)
openssl req -new -x509 \
    -key keys/dm-verity/rsa3k-key.pem \
    -out keys/dm-verity/rsa3k-cert.pem \
    -days 3650 \
    -subj "/CN=dm-verity-signer/O=Physical AI/OU=Embedded Security"

# Verify
openssl x509 -in keys/dm-verity/rsa3k-cert.pem -text -noout | head -20
openssl rsa  -in keys/dm-verity/rsa3k-key.pem -check -noout
```

### Security Notes

- **Never commit keys to git.** The `.gitignore` excludes `keys/`.
- For production, use an **HSM** (PKCS#11) or **vault-based** key management. The openssl approach is for development/CI.
- RSA-3072 provides ~128-bit security, meeting NIST SP 800-57 recommendations through 2031.
- **Key rotation**: Generate new keys, rebuild, re-flash. There is no in-field key update mechanism with dm-verity; a full re-flash is required.

---

## Persistent Cache

Downloads and shared-state cache are stored outside the build directory for persistence across `kas` invocations:

```
yocto_orin/
├── downloads/        ← DL_DIR: source tarballs (~10-30 GB)
├── sstate-cache/     ← SSTATE_DIR: compiled artifacts (~30-80 GB)
└── build/            ← TMPDIR: active build workspace
```

To share across machines, copy or NFS-mount `downloads/` and `sstate-cache/`.

---

## SDK Docker Container

A Docker image containing the Yocto cross-compilation SDK for `aarch64` (Jetson Orin Nano).

### Fast Path (pre-built SDK)

Build the SDK locally first, then package it:

```bash
# 1. Build SDK
./build.sh -- --target demo-image-base -c populate_sdk

# 2. Find the installer
ls build/tmp/deploy/sdk/*.sh

# 3. Build Docker image with pre-built SDK (~5 min)
./kas-docker.sh --sdk-installer build/tmp/deploy/sdk/poky-glibc-x86_64-*.sh
```

### Full Build (CI, slow)

Build everything inside Docker (4–8+ hours):

```bash
./kas-docker.sh
```

### Tagging & Pushing

```bash
# Push :head only (default)
./kas-docker.sh

# Push :head + :stable + :latest
./kas-docker.sh --stable

# Custom tag
./kas-docker.sh --tag v1.2.0

# Build only, no push
./kas-docker.sh --no-push
```

Images are pushed to: `docker.io/drdeshmukh97/yocto-orin`

### Using the SDK Container

```bash
# Interactive shell (SDK env auto-sourced)
docker run -it -v $(pwd)/my-app:/work drdeshmukh97/yocto-orin:stable

# Inside container — cross-compile a C application
$CC -o my-app main.c -lm
file my-app
# my-app: ELF 64-bit LSB executable, ARM aarch64, ...

# One-shot compilation
docker run --rm -v $(pwd):/work drdeshmukh97/yocto-orin:stable \
    sh -c '$CC -O2 -o app main.c && file app'

# Check cross-compiler version
docker run --rm drdeshmukh97/yocto-orin:stable aarch64-poky-linux-gcc --version
```

The SDK includes:

- `aarch64-poky-linux-gcc` / `g++` cross-compiler
- Target sysroot with all libraries from `demo-image-base`
- `cmake`, `ninja-build`, `pkg-config`
- Environment script auto-sets `CC`, `CXX`, `LD`, `SDKTARGETSYSROOT`

---

## Flashing

### Prerequisites

- USB-C cable connected to the Jetson Orin Nano's **USB recovery port**
- NVIDIA L4T BSP tools (installed by meta-tegra into the deploy directory)
- Host support for USB storage handoff (`udisksctl`, provided by `udisks2`)
- Device in **recovery mode**

This repo targets **Jetson Orin** developer kits only. Legacy Jetson Nano / T210
hardware requires a different BSP and is out of scope here.

### Enter Recovery Mode

1. Connect the USB-C cable to the host machine.
2. On the Jetson Orin Nano devkit:
   - If using buttons: Hold the **Force Recovery** button, tap **Reset**, release Force Recovery after 2 seconds.
   - If using header pins (J14): Short **pin 9 (FC_REC)** to **pin 10 (GND)**, then power on.
3. Verify on host:

```bash
lsusb | grep -i nvidia
# Bus 001 Device 0XX: ID 0955:7523 NVIDIA Corp. APX
```

### NVMe Flash (Primary)

Use the provided `flash.sh` wrapper. It handles host dependency installation,
archive extraction into a clean `flash-artifacts/` directory, and invokes
`doflash.sh` — all in one command.

For the NVMe target, `doflash.sh` uses the initrd flash flow. The Jetson will
reboot during deployment by design: it first boots via RCM, then comes back as
USB storage so the host can write the NVMe and QSPI partitions.

> **Important:** `doflash.sh` is packaged *inside* the `*.tegraflash.tar.gz`
> archive produced by the build. Do **not** try to run it directly from
> `build/tmp/deploy/images/…`; `flash.sh` extracts it correctly.

```bash
# Put the Jetson in recovery mode first (see above), then:
./flash.sh

# Extract only (no flash) — useful for inspection:
./flash.sh --no-flash

# Keep flash-artifacts/ after flashing:
./flash.sh --no-cleanup
```

`flash.sh` options:

| Option | Default | Description |
|---|---|---|
| `--machine MACHINE` | `jetson-orin-nano-devkit-nvme` | Yocto MACHINE name |
| `--image IMAGE` | `demo-image-base` | Image recipe name |
| `--usb-instance N` | auto | Forward `--usb-instance` to `doflash.sh` |
| `--erase-nvme` | off | Erase the NVMe drive during initrd flash |
| `--force` | off | Continue if recovery mode is not detected |
| `--no-flash` | off | Extract only; skip `doflash.sh` |
| `--no-cleanup` | off | Preserve `flash-artifacts/` after flash |
| `--skip-deps` | off | Skip host dependency check |

#### USB Device ID Reference

Verify the Jetson USB state with `lsusb` before and after flashing:

| USB ID | Meaning |
|---|---|
| `0955:7523` | APX (recovery mode) — **ready to flash** |
| `0955:7020` | L4T running (normal boot) — put in recovery mode first |

> **Note:** `flash.sh` aborts if no recovery-mode device is detected, unless you
> pass `--force`. If the flash fails after extraction, the script preserves the
> `flash-artifacts/` directory and any `log.initrd-flash.*` or `device-logs-*`
> output for debugging.

### NVMe Partition Layout

The flash process creates:

| Partition | Device | Contents |
|---|---|---|
| QSPI | mtdblock0 | MB1, MB2, UEFI bootloader, BCT |
| APP | nvme0n1p1 | Root filesystem (ext4 + dm-verity) |
| APP_b | nvme0n1p2 | A/B rootfs slot (if configured) |

### Non-NVMe Devkit Flash (Fallback)

Use the `jetson-orin-nano-devkit` MACHINE for the non-NVMe Orin devkit layout.
This remains an Orin target; it is **not** a legacy Jetson Nano BSP.

#### Using tegra-flash (recommended)

```bash
# Rebuild for the non-NVMe devkit path
./build.sh --machine jetson-orin-nano-devkit --rootfs rw --no-dm-verity

cd build/tmp/deploy/images/jetson-orin-nano-devkit/
sudo ./doflash.sh
```

#### Using bmaptool (raw image write)

`bmaptool` is useful for writing pre-built images to removable storage from the
host (for example, a card or other block device in an external reader). It does
**not** flash the QSPI bootloader — only the rootfs partition.

```bash
# Install bmaptool
sudo apt-get install -y bmap-tools

# Write rootfs WIC image to removable media on the host
sudo bmaptool copy \
    demo-image-base-jetson-orin-nano-devkit.wic.zst \
    /dev/sdX

# Or with explicit bmap file for sparse write (faster)
sudo bmaptool copy \
    --bmap demo-image-base-jetson-orin-nano-devkit.wic.bmap \
    demo-image-base-jetson-orin-nano-devkit.wic.zst \
    /dev/sdX
```

> **Warning:** `bmaptool` writes only the rootfs. The QSPI firmware must be flashed separately via `tegra-flash.py` at least once. For initial board bring-up, always use the full tegra-flash flow.

### Post-Flash Verification

After boot, verify the security configuration on-device:

```bash
# Check rootfs is read-only
mount | grep " / "
# /dev/nvme0n1p1 on / type ext4 (ro,...)

# Check dm-verity status
sudo veritysetup status rootfs
# type:        VERITY
# status:      verified

# Check systemd mount unit
systemctl show -.mount | grep Options
# Options=ro

# If overlayfs mode — verify overlay is active
mount | grep overlay
# overlay on /overlay/merged type overlay (rw,lowerdir=/,upperdir=/overlay/upper,...)
```

### Post-Deploy Networking

For first boot and manual SSH or Wi-Fi setup, use a writable bring-up image:

```bash
./build.sh --rootfs rw --no-dm-verity
./flash.sh
```

Once the Jetson boots, configure networking with the CLI tools now included in
the image:

```bash
# Discover interfaces
ip link show
iw dev

# Verify SSH is up
systemctl status sshd

# Replace wlan0 with the interface reported by `iw dev`
ip link set wlan0 up

cat >/etc/wpa_supplicant/wpa_supplicant-wlan0.conf <<'EOF'
ctrl_interface=/run/wpa_supplicant
update_config=1
network={
    ssid="YOUR_WIFI_SSID"
    psk="YOUR_WIFI_PASSWORD"
}
EOF

wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
udhcpc -i wlan0
ip -4 addr show wlan0
```

Then connect over SSH:

```bash
ssh root@<jetson-ip>
```

After bring-up is stable, rebuild with the hardened read-only / dm-verity flow
for production images.

---

## Repository Structure

```
yocto_orin/
├── kas-project.yml                     # kas build config (pinned layers, local.conf)
├── build.sh                            # Build orchestrator (cores, rootfs mode, dm-verity)
├── Dockerfile                          # Multi-stage: Yocto builder → SDK container
├── kas-docker.sh                       # Docker build & push script (stable/head tags)
├── .gitignore
├── .dockerignore
├── keys/                               # ⛔ NOT in git
│   └── dm-verity/
│       ├── rsa3k-key.pem
│       └── rsa3k-cert.pem
├── meta-physical-ai/
│   ├── conf/
│   │   └── layer.conf
│   ├── recipes-core/
│   │   ├── images/
│   │   │   └── demo-image-base.bb          ← top-level image target
│   │   ├── systemd/
│   │   │   └── systemd-conf/
│   │   │       ├── systemd-conf_%.bbappend
│   │   │       └── files/
│   │   │           ├── 10-readonly-root.conf
│   │   │           └── 10-overlayfs-tmp.conf
│   │   └── overlayfs-setup/
│   │       ├── overlayfs-setup.bb
│   │       └── files/
│   │           └── overlayfs-rootfs.service
│   └── COPYING.MIT
├── tmp/                                # ⛔ NOT in git (kas override YAMLs)
├── downloads/                          # ⛔ NOT in git (DL_DIR)
├── sstate-cache/                       # ⛔ NOT in git (SSTATE_DIR)
└── build/                              # ⛔ NOT in git (TMPDIR)
```

---

## Security Hardening Checklist

| Control | Status | Notes |
|---|---|---|
| dm-verity rootfs signing | ✅ | RSA-3K, Merkle tree integrity |
| Read-only rootfs | ✅ | IMAGE_FEATURES + systemd drop-in |
| debug-tweaks removed | ✅ | No empty root password, no debug serial |
| Overlay (optional) | ✅ | tmpfs-backed, volatile only |
| UEFI Secure Boot | ⬜ | Orthogonal — configure via NVIDIA's secureboot fuse flow |
| Key rotation | ⬜ | Requires rebuild + re-flash |
| SELinux / AppArmor | ⬜ | Can be layered via meta-selinux |

---

## Updating Layer Pins

To update to latest scarthgap HEAD:

```bash
# Get current HEAD SHAs
git ls-remote https://git.yoctoproject.org/poky refs/heads/scarthgap | cut -f1
git ls-remote https://github.com/OE4T/meta-tegra.git refs/heads/scarthgap | cut -f1
git ls-remote https://git.openembedded.org/meta-openembedded refs/heads/scarthgap | cut -f1
git ls-remote https://git.yoctoproject.org/meta-security refs/heads/scarthgap | cut -f1

# Update refspec values in kas/layers.yml, then rebuild
./build.sh
```

---

## License

`meta-physical-ai` layer: MIT. See [meta-physical-ai/COPYING.MIT](meta-physical-ai/COPYING.MIT).

Individual Yocto layers retain their own licenses (GPLv2 for poky, MIT/GPLv2 for meta-tegra, etc.).
