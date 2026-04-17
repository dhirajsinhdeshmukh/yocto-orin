# Project Guide — Hardened Jetson Orin Nano BSP

Quick reference for navigating the repo, adding things, and flashing the board.

---

## File Map

```
kas-project.yml                  ENTRY POINT — machine: jetson-orin-nano-devkit-nvme, distro: poky
kas/
├── layers.yml                   → ADD NEW YOCTO LAYERS HERE
├── local-conf.yml               → dm-verity keys, cache paths, build tuning
├── image-packages.yml           → PACKAGES INSTALLED ON THE JETSON (rootfs)
└── sdk.yml                      → CROSS-COMPILE SDK: host tools + target sysroot libs

meta-physical-ai/                CUSTOM LAYER — our own recipes
├── conf/layer.conf              → layer registration, dependencies
├── recipes-core/images/         → demo-image-base.bb (top-level image target)
├── recipes-core/systemd/        → read-only rootfs systemd drop-in
└── recipes-core/overlayfs-setup → tmpfs-backed writable overlay (field debug)

build.sh                         BUILD ORCHESTRATOR — cores, rootfs mode, dm-verity
                                 Auto-activates .venv; writes override to tmp/ (not /tmp)
kas-docker.sh                    SDK DOCKER — builds + pushes drdeshmukh97/yocto-orin
Dockerfile                       Multi-stage: full Yocto builder → slim SDK image
keys/dm-verity/                  RSA-3K signing keys — NOT in git, generate locally
tmp/                             Ephemeral kas override YAMLs — gitignored
```

---

## Common Tasks

### Understand the NVMe partition layout

```
nvme0n1  (~932 GB on 1 TB NVMe)
├── p1   APP            64 GiB   /             Active rootfs slot A
├── p2   APP_b          64 GiB   (unmounted)   Inactive rootfs slot B (OTA target)
├── p3   A_kernel      128 MiB   (unmounted)   Slot-A kernel image
├── p4   A_kernel-dtb  768 KiB   (unmounted)   Slot-A device tree
├── p5   A_reserved  31.6 MiB   (unmounted)   Reserved space after A_kernel-dtb
├── p6   B_kernel      128 MiB   (unmounted)   Slot-B kernel image
├── p7   B_kernel-dtb  768 KiB   (unmounted)   Slot-B device tree
├── p8   B_reserved  31.6 MiB   (unmounted)   Reserved space after B_kernel-dtb
├── p9   recovery       80 MiB   (unmounted)   Recovery kernel
├── p10  recovery-dtb  512 KiB   (unmounted)   Recovery device tree
├── p11  esp             2 GiB   /boot/efi     Primary EFI system partition (UEFI launcher)
├── p12  recovery_alt   80 MiB   (unmounted)   Backup recovery kernel
├── p13  recovery-dtb_alt 512 KiB (unmounted)  Backup recovery device tree
├── p14  esp_alt         2 GiB   (unmounted)   Backup EFI system partition
└── p15  UDA           ~799 GiB  /data         User data — fills all remaining space
```

To **change partition sizes**: edit the XML layout file, rebuild, and re-flash with `--erase-nvme`:
```bash
# 1. Edit sizes in:
vim meta-physical-ai/recipes-bsp/tegra-binaries/files/flash_l4t_t234_nvme_physical_ai_rootfs_ab.xml

# 2. Rebuild tegraflash artifact
./build.sh --machine jetson-orin-nano-devkit-nvme --rootfs rw --no-dm-verity

# 3. Re-flash (erase required when partition table changes)
./flash.sh --erase-nvme
```

> **Important:** UDA (p15) uses `allocation_attribute 0x808` (fill-to-end) — its
> size is computed automatically from remaining disk space. Do **not** give it a
> hardcoded byte count in the XML.

---

### Add a package to the Jetson rootfs
Edit [kas/image-packages.yml](kas/image-packages.yml):
```yaml
image-base: |
  IMAGE_INSTALL:append = " htop python3 can-utils"
```

### Add a library to the SDK sysroot
Edit [kas/sdk.yml](kas/sdk.yml):
```yaml
sdk-target: |
  TOOLCHAIN_TARGET_TASK:append = " opencv-dev protobuf-dev"
```

### Add a new Yocto layer
Edit [kas/layers.yml](kas/layers.yml) — add a new repo block with a pinned SHA:
```yaml
meta-openembedded:
  url: "https://git.openembedded.org/meta-openembedded"
  refspec: <sha>    # git ls-remote <url> refs/heads/scarthgap | cut -f1
  layers:
    meta-oe:        # subdirectory inside the repo
    meta-python:
```

> **Layer path convention:** Some repos (e.g. `meta-tegra`, `meta-security`) have their
> `conf/layer.conf` at the repo root — use `.` as the layer key, not the repo name.
> `meta-openembedded` is different: each sublayer lives in its own subdirectory (`meta-oe/`,
> `meta-python/`, etc.), so the subdirectory name is the correct key.
> When in doubt: `ls <cloned-repo>/` and look for subdirs containing `conf/layer.conf`.

### Change the target machine
Prefer a one-off override via `build.sh`:

```bash
./build.sh --machine jetson-orin-nano-devkit-nvme --rootfs rw --no-dm-verity
./build.sh --machine jetson-orin-nano-devkit --rootfs rw --no-dm-verity
```

If you want to change the repo default instead, edit [kas-project.yml](kas-project.yml):
```yaml
machine: jetson-orin-nano-devkit-nvme    # NVMe boot (default)
# machine: jetson-orin-nano-devkit       # non-NVMe Orin devkit layout
```

> `distro` is always `poky`. `meta-tegra` provides the MACHINE definitions only.

---

## Building

```bash
# Generate signing keys first (one-time)
mkdir -p keys/dm-verity
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
    -out keys/dm-verity/rsa3k-key.pem
openssl req -new -x509 -key keys/dm-verity/rsa3k-key.pem \
    -out keys/dm-verity/rsa3k-cert.pem -days 3650 \
    -subj "/CN=dm-verity-signer"

# Production build (ro rootfs + dm-verity)
./build.sh --cores 8

# Dev build (writable rootfs, no signing)
./build.sh --rootfs rw --no-dm-verity

# Field debug (read-only base + volatile writable overlay)
./build.sh --rootfs overlayfs --cores 4
```

---

## Flashing — Jetson Orin Nano Super (DevKit)

This repo currently targets the Orin Nano Super path already encoded in the
generated flash artifacts:

- Carrier: **P3768**
- Module: **P3767-0005**
- Default MACHINE: `jetson-orin-nano-devkit-nvme`

Use `jetson-orin-nano-devkit-nvme` for the NVMe flow. Use
`jetson-orin-nano-devkit` only for the non-NVMe Orin devkit layout.
Legacy Jetson Nano / T210 hardware is out of scope for this BSP.

### Step 1 — Enter Recovery Mode

1. Power off the board.
2. Locate **J14** (10-pin recovery header, near the USB-C port on the carrier).
3. Short **pin 9 (FC_REC)** to **pin 10 (GND)** with a jumper.
4. Connect USB-C to your host, then power on.
5. Verify on host:
   ```bash
   lsusb | grep -i nvidia
   # Bus 00X Device 0XX: ID 0955:7523 NVIDIA Corp. APX
   ```
6. Remove the jumper (leave it out for normal boot).

### Step 2 — Flash with flash.sh

The build produces a self-contained `*.tegraflash.tar.gz` archive in the deploy
directory. `doflash.sh` and all companion tools live **inside** that archive —
they are not extracted into the build directory by default.

Use the `flash.sh` wrapper to handle extraction, dependency checks, and flashing
in one step:

```bash
# From the repo root:
./flash.sh
```

`flash.sh` will:
1. Install host dependencies (`device-tree-compiler`, `usbutils`, `udisks2`) if missing
2. Locate `build/tmp/deploy/images/jetson-orin-nano-devkit-nvme/demo-image-base-jetson-orin-nano-devkit-nvme.rootfs.tegraflash.tar.gz`
3. Remove any previously extracted flash artifacts
4. Extract the full archive into `flash-artifacts/jetson-orin-nano-devkit-nvme/`
5. Summarize the initrd flash flow from `.env.initrd-flash`
6. Warn if the Jetson is not in recovery mode
7. Run `sudo ./doflash.sh` from the extracted directory
8. Preserve `flash-artifacts/` and any `log.initrd-flash.*` / `device-logs-*` output if flashing fails

> **Expected behavior:** NVMe flashing uses the initrd flash path. The Jetson
> reboots during deployment by design, then returns as USB storage so the host
> can push the flash package and write partitions.

**USB device IDs** — verify with `lsusb` before flashing:

| USB ID | Meaning |
|---|---|
| `0955:7523` | APX (recovery mode) — **ready to flash** |
| `0955:7020` | L4T running (normal boot) — put in recovery mode first |

> **Safety:** `flash.sh` never modifies the tegraflash tarball. When a flash
> fails, the extracted artifacts and logs are preserved automatically.

### Step 3 — Flash the Non-NVMe Devkit Path

For the non-NVMe Orin devkit layout (`jetson-orin-nano-devkit` MACHINE):

```bash
./flash.sh --machine jetson-orin-nano-devkit
```

Alternatively, for rootfs-only re-flash (skips QSPI/bootloader — faster):

```bash
# Extract first, then use bmaptool directly
./flash.sh --no-flash --machine jetson-orin-nano-devkit
sudo bmaptool copy \
    flash-artifacts/jetson-orin-nano-devkit/demo-image-base-jetson-orin-nano-devkit.wic.zst \
    /dev/sdX
```

> **Note on QSPI:** The first flash (or after a boot firmware update) must go through
> `doflash.sh` / `tegra-flash.py` to update QSPI firmware (MB1, UEFI, BCT). `bmaptool`
> only writes the rootfs — safe for re-flashing the OS without touching the bootchain.


### Step 4 — Verify on Device

```bash
# Root filesystem is read-only
mount | grep " / "
# /dev/nvme0n1p1 on / type ext4 (ro,relatime)

# dm-verity is active
sudo veritysetup status rootfs
# type:   VERITY
# status: verified

# systemd enforces ro at mount level too
systemctl show -.mount | grep Options
# Options=ro
```

### Step 5 — Post-Deploy Networking (Writable Bring-Up)

For first boot and manual SSH setup, use a writable image and erase the NVMe if
you just changed the partition layout:

```bash
./build.sh --rootfs rw --no-dm-verity
./flash.sh --erase-nvme
```

The first boot service grows the active rootfs to fill its slot and formats the
`UDA` partition as `/data` if needed.

For wired networking, the devkit ethernet interface comes up with DHCP by
default. From the host:

```bash
nmap -sn 192.168.1.0/24 | grep -A1 -i nvidia
ssh root@<jetson-ip>
```

On the Jetson, Wi-Fi remains optional:

```bash
# Discover interfaces if you need Wi-Fi
ip link show
iw dev

# Verify SSH is running
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

Then connect from the host:

```bash
ssh root@<jetson-ip>
```

### Stage an A/B update over SSH

Once the board has been flashed once with the custom NVMe layout, you can write
the inactive rootfs slot over the network:

```bash
./build.sh --machine jetson-orin-nano-devkit-nvme --rootfs rw --no-dm-verity
./network-ab-update.sh --host <jetson-ip> --reboot
```

This helper updates only `APP` / `APP_b`. It does not repartition the NVMe or
update QSPI firmware, and it currently refuses dm-verity images.

---

## SDK Docker

```bash
# Build SDK image and push :head
./kas-docker.sh

# Build + push :head, :stable, :latest
./kas-docker.sh --stable

# Cross-compile inside the container
docker run --rm -v $(pwd)/my-app:/work drdeshmukh97/yocto-orin:stable \
    sh -c '$CC -O2 -o app main.c && file app'
# app: ELF 64-bit LSB executable, ARM aarch64, ...
```

---

## Updating Layer Pins

```bash
# Get fresh scarthgap HEADs
git ls-remote https://git.yoctoproject.org/poky refs/heads/scarthgap | cut -f1
git ls-remote https://github.com/OE4T/meta-tegra.git refs/heads/scarthgap | cut -f1
git ls-remote https://git.openembedded.org/meta-openembedded refs/heads/scarthgap | cut -f1
git ls-remote https://git.yoctoproject.org/meta-security refs/heads/scarthgap | cut -f1

# Update refspec values in kas/layers.yml, then validate
python3 -c "import yaml; yaml.safe_load(open('kas/layers.yml'))" && echo "OK"
./build.sh --rootfs rw --no-dm-verity  # test build
```

---

## Build & Debug Commands

### Common build entrypoints

```bash
# Full production build (default machine from kas-project.yml)
kas build kas-project.yml

# Writable bring-up build via wrapper (recommended for first boot)
./build.sh --rootfs rw --no-dm-verity

# Override the machine for one run
./build.sh --machine jetson-orin-nano-devkit --rootfs rw --no-dm-verity

# Build a specific image target
kas build --target demo-image-base kas-project.yml

# Build the SDK installer
kas build --target demo-image-base -c populate_sdk kas-project.yml

# Build the extensible SDK
kas build --target demo-image-base -c populate_sdk_ext kas-project.yml

# Parse recipes without building
kas shell kas-project.yml -c "bitbake -n demo-image-base"
```

### Shell-based inspection commands

```bash
# Show loaded layers and priorities
kas shell kas-project.yml -c "bitbake-layers show-layers"

# Show which layer a recipe comes from
kas shell kas-project.yml -c "bitbake-layers show-recipes <recipe>"

# Find recipes matching a pattern
kas shell kas-project.yml -c "bitbake -s | grep <pattern>"

# Dump image install variables for a recipe
kas shell kas-project.yml -c "bitbake -e <recipe> | grep -A5 '^IMAGE_INSTALL'"

# Inspect dependency graph output
kas shell kas-project.yml -c "bitbake -g demo-image-base && grep <recipe> pn-depends.dot"

# Reverse provider lookup
kas shell kas-project.yml -c "bitbake-layers show-recipes -f <recipe>"
```

### Re-run and debug individual tasks

```bash
# Re-run a task
kas build --target <recipe> -c compile kas-project.yml

# Force a task to re-run
kas shell kas-project.yml -c "bitbake <recipe> -c compile -f"

# Clean build artifacts
kas build --target <recipe> -c clean kas-project.yml

# Clean sstate for a recipe
kas build --target <recipe> -c cleansstate kas-project.yml

# Open a recipe devshell
kas shell kas-project.yml -c "bitbake <recipe> -c devshell"

# List all tasks a recipe provides
kas shell kas-project.yml -c "bitbake <recipe> -c listtasks"
```

### Image and package inspection

```bash
# Re-assemble the image after package changes
kas build --target demo-image-base kas-project.yml

# Force the rootfs task only
kas shell kas-project.yml -c "bitbake demo-image-base -c rootfs -f"

# List final image packages
kas shell kas-project.yml -c "cat build/tmp/deploy/images/*/demo-image-base*.manifest"

# Query pkgdata
kas shell kas-project.yml -c "oe-pkgdata-util list-pkgs -p build/tmp/pkgdata/jetson-orin-nano-devkit-nvme"

# Check which package owns a path
kas shell kas-project.yml -c "oe-pkgdata-util find-path /usr/bin/my-app"
```

### Failure logs and cache debugging

```bash
# Find recent task logs
find build/tmp/work -name "log.do_*" -type f | tail -20

# Inspect a failure log
cat build/tmp/work/aarch64-poky-linux/<recipe>/<ver>/temp/log.do_compile

# Compare task signatures
kas shell kas-project.yml -c "bitbake-diffsigs build/tmp/stamps/ <recipe>"

# Check why a cache hit was missed
kas shell kas-project.yml -c "bitbake-diffsigs build/tmp/sigdata.<old>.sigdata build/tmp/sigdata.<new>.sigdata"

# Fetch everything without building
kas shell kas-project.yml -c "bitbake --runall=fetch demo-image-base"

# Parse all recipes and stop
kas shell kas-project.yml -c "bitbake --parse-only"
```

### Common failure patterns

| Symptom | Likely cause | Fix |
|---|---|---|
| `ERROR: Nothing PROVIDES '<x>'` | Missing layer or recipe name typo | Add the layer to `kas/layers.yml` |
| `ERROR: <recipe> was skipped` | `COMPATIBLE_MACHINE` doesn't match | Wrong MACHINE or recipe needs layer dependency |
| `do_fetch` fails with 404 | Upstream URL changed or refspec wrong | Update `SRC_URI` or `SRCREV` in recipe |
| `do_compile` C/C++ error | Patch doesn't apply, or sysroot missing dep | Check `log.do_patch`, add missing `DEPENDS` |
| `do_package_qa` failure | Bad file ownership / permissions in package | Fix `do_install` — use `install -m <mode>` |
| `ERROR: Multiple .bb files are due to be built` | Two layers provide same recipe | Set `PREFERRED_PROVIDER` or adjust layer priority |
| `All concatenated config files must belong to the same repository` | kas 5.2+ override file written outside the repo | Keep overrides under `${SCRIPT_DIR}/tmp/` |
| Layer directory does not exist error | Layer key in `kas/layers.yml` names a non-existent subdir | Use `.` for flat repos and subdir names for repo sublayers |
