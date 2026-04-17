# Device Tree Guide — NVIDIA Jetson Orin Nano Super

This guide explains how device tree blobs (DTBs) are selected, built, and
applied for the Jetson Orin Nano Super on this BSP. It covers the selection
mechanism, artifact inventory, partition maps, and how to write your own
device tree overlay.

---

## Table of Contents

1. [Background: What is a Device Tree?](#1-background-what-is-a-device-tree)
2. [Hardware Identification](#2-hardware-identification)
3. [How the Correct DTB is Selected](#3-how-the-correct-dtb-is-selected)
4. [Device Tree Artifacts](#4-device-tree-artifacts)
5. [Partition Layout](#5-partition-layout)
6. [DTB Selection at Flash Time](#6-dtb-selection-at-flash-time)
7. [DTB Selection at Runtime](#7-dtb-selection-at-runtime)
8. [Writing a Custom Device Tree Overlay](#8-writing-a-custom-device-tree-overlay)
9. [Applying an Overlay at Build Time](#9-applying-an-overlay-at-build-time)
10. [Debugging Device Tree Issues](#10-debugging-device-tree-issues)
11. [Reference](#11-reference)

---

## 1. Background: What is a Device Tree?

A device tree is a data structure that describes hardware to software without
hard-coding it into the kernel. For ARM SoCs like the NVIDIA Tegra234 (Orin),
the bootloader loads the device tree blob (DTB) into memory and passes it to
the Linux kernel, which uses it to bind drivers to peripherals.

NVIDIA extends the standard Linux DT mechanism with:

- **Board-specific overlays** — applied at flash time to encode carrier-board
  configuration into the stored DTB
- **Dynamic overlays** (DTBOs) — loaded by the UEFI firmware at runtime,
  enabling runtime hardware detection (e.g., attached camera modules)
- **Boot-time config generation** — `tegra-flash.py` runs `dtc`/`fdtput` during
  flash to inject registers-based blob (BPMP, MB1BCT) into the QSPI partitions

---

## 2. Hardware Identification

This BSP targets the following hardware configuration:

| Parameter | Value |
|---|---|
| SoC | NVIDIA Tegra T234 (Orin) |
| CHIP ID | `0x23` |
| Module | P3767-0005 (8 GB, 67 TOPS — Orin Nano Super) |
| Carrier | P3768 (Developer Kit) |
| BoardID | `3767` |
| BoardSKU | `0005` |
| Storage | NVMe (via M.2 slot on carrier) |
| Yocto MACHINE | `jetson-orin-nano-devkit-nvme` |

You can verify the board identity at runtime:

```bash
# Module and carrier IDs are written to EEPROM and reported by CBoot/MB1
cat /proc/device-tree/nvidia,boardids    2>/dev/null
cat /proc/device-tree/model              2>/dev/null
# NVIDIA Jetson Orin Nano Developer Kit

# SoC chip ID
cat /sys/bus/platform/devices/*/chip_id 2>/dev/null || \
  grep 'TEGRA_CHIP_ID' /sys/module/tegra_fuse/parameters/ 2>/dev/null
```

---

## 3. How the Correct DTB is Selected

The selection happens across four layers:

```
meta-tegra layer
   └─ MACHINE = jetson-orin-nano-devkit-nvme
         └─ DTBFILE  (in machine conf)
               └─ tegra234-p3768-0000+p3767-0005-nv-super.dtb
                     │
                     ├─ flash.xml.in  (substitutes @DTBFILE@)
                     │        └─ tegra-flash.py burns DTB to QSPI DTB partition
                     │
                     └─ doflash.sh invocation args
                              └─ --dtb tegra234-p3768-0000+p3767-0005-nv-super.dtb
```

### Layer 1 — MACHINE definition (meta-tegra)

`meta-tegra/conf/machine/jetson-orin-nano-devkit-nvme.conf` sets:

```bitbake
DTBFILE = "tegra234-p3768-0000+p3767-0005-nv-super.dtb"
TBCDTB_FILE = "tegra234-p3768-0000+p3767-0005-nv-super.dtb"
```

### Layer 2 — flashvars

`flashvars` (inside the tegraflash archive) encodes the board check:

```
CHIPID=0x23
CHECK_BOARDID=3767
CHECK_BOARDSKU=0005
TBCDTB_FILE=tegra234-p3768-0000+p3767-0005-nv-super.dtb
```

`tegra-flash.py` reads `flashvars` and validates that the connected board
matches before proceeding. This prevents accidentally flashing the wrong image.

### Layer 3 — flash.xml.in

`flash.xml.in` is a template partition layout. The `@DTBFILE@` and
`@TBCDTB_FILE@` tokens are substituted by `tegra-flash.py` at flash time:

```xml
<partition name="DTB" type="data">
    <filename> @DTBFILE@ </filename>
    ...
</partition>
```

### Layer 4 — Dynamic overlay loading (runtime)

The UEFI firmware reads `UEFI_EXTRA_DTB` and `L4TConfiguration.dtbo` from the
QSPI `A_BOOTCONFIG`/`B_BOOTCONFIG` partitions and merges them into the live DT
before handing off to Linux.

---

## 4. Device Tree Artifacts

After a build, the following DT-related files are present in the deploy directory:

```
build/tmp/deploy/images/jetson-orin-nano-devkit-nvme/
│
│   ── Kernel device tree blobs ──
├── tegra234-p3768-0000+p3767-0005-nv-super.dtb   ← primary DTB (NVMe + Super)
├── tegra234-p3768-0000+p3767-0005-nv.dtb          ← Non-Super variant (reference)
│
│   ── Dynamic overlay blobs ──
├── tegra234-p3768-0000+p3767-0005-dynamic.dtbo    ← runtime hardware discovery
├── L4TConfiguration.dtbo                          ← L4T-managed config overlay
│
│   ── BCT / MB1 configs (DT-formatted) ──
├── tegra234-mb1-bct-*.dts                         ← Memory BCT (DTS source)
├── tegra234-mb2-bct-*.dts                         ← MB2 BCT
├── tegra234-memfbct-*.dts                         ← Memory frequency BCT
│
│   ── UEFI-side DTB ──
└── uefi_jetson_with_dtb.bin                        ← UEFI binary with DT embedded
```

The `tegra234-p3768-0000+p3767-0005-nv-super.dtb` naming breakdown:

| Segment | Meaning |
|---|---|
| `tegra234` | SoC family (T234 = Orin) |
| `p3768` | Carrier board (Developer Kit) |
| `0000` | Carrier board revision |
| `p3767` | Module (Orin Nano) |
| `0005` | Module SKU (8 GB Super variant) |
| `nv` | NVIDIA reference configuration |
| `super` | Orin Nano Super variant (67 TOPS, 1024 CUDA cores) |

---

## 5. Partition Layout

### QSPI Flash (mtdblock0) — 64 MiB total

The QSPI NOR flash stores bootloader stages, BCTs, and the DTB. It is written
by `tegra-flash.py` during the flash process.

| Partition | A/B | Size | Contents |
|---|---|---|---|
| `BCT` | no | 512 KiB | Boot configuration table |
| `A_MB1` / `B_MB1` | yes | 512 KiB | MB1 (secure monitor, lowest-level firmware) |
| `A_MB1_BCT` / `B_MB1_BCT` | yes | 64 KiB | MB1 BCT |
| `A_MEM_BCT` / `B_MEM_BCT` | yes | 512 KiB | Memory training BCT |
| `A_MB2` / `B_MB2` | yes | 1 MiB | MB2 (BPMP firmware stub) |
| `A_SPE_DTB` / `B_SPE_DTB` | yes | 64 KiB | SPE device tree |
| `A_BPMP_DTB` / `B_BPMP_DTB` | yes | 256 KiB | BPMP coprocessor device tree |
| `DTB` | no | 1 MiB | **Kernel DTB** (`tegra234-p3768-...super.dtb`) |
| `A_TBC` / `B_TBC` | yes | 2 MiB | Trusted Boot Chain (UEFI) |
| `A_BOOTCONFIG` / `B_BOOTCONFIG` | yes | 256 KiB | UEFI ext-linuxconf + overlays |
| `VER` | no | 64 KiB | Version info |

### NVMe / eMMC — APP Partitions

These are defined in the custom NVMe layout XML shipped by this repo:
`meta-physical-ai/recipes-bsp/tegra-binaries/files/flash_l4t_t234_nvme_physical_ai_rootfs_ab.xml`.

| Partition | Device | Size | Contents |
|---|---|---|---|
| `APP` | `nvme0n1p1` | 64 GiB | Active root filesystem slot |
| `APP_b` | `nvme0n1p2` | 64 GiB | Inactive root filesystem slot |
| `esp` | `nvme0n1p11` | 2 GiB | Primary EFI system partition |
| `esp_alt` | `nvme0n1p14` | 2 GiB | Backup EFI system partition |
| `UDA` | `/dev/disk/by-partlabel/UDA` | remainder on the configured NVMe | Persistent `/data` area |

> The repo now ships a custom 1 TB NVMe layout:
> `flash_l4t_t234_nvme_physical_ai_rootfs_ab.xml`. The exact device size is
> derived from `TEGRA_EXTERNAL_DEVICE_SECTORS = "1953525168"`.

---

## 6. DTB Selection at Flash Time

During `./flash.sh` → `doflash.sh` → `tegra-flash.py`:

1. `tegra-flash.py` reads `flashvars` to determine `DTBFILE` and `TBCDTB_FILE`
2. It validates the connected board's EEPROM identity against `CHECK_BOARDID`
   and `CHECK_BOARDSKU`
3. It substitutes `@DTBFILE@` in `flash.xml.in` with
   `tegra234-p3768-0000+p3767-0005-nv-super.dtb`
4. The compiled DTB (plus applied overlays) is written to the `DTB` QSPI
   partition
5. The UEFI binary with embedded DTB is written to `A_TBC` / `B_TBC`

If the board identity check fails (wrong module in the carrier), `tegra-flash.py`
aborts with:

```
Error: Board mismatch! Expected BoardID=3767, SKU=0005
```

---

## 7. DTB Selection at Runtime

On boot:

1. **MB1** reads BCT from QSPI `A_MB1_BCT`, validates DRAM config
2. **UEFI** (loaded from `A_TBC`) reads the kernel DTB from QSPI `DTB`
3. UEFI applies overlays from `A_BOOTCONFIG` (e.g., `L4TConfiguration.dtbo`,
   `tegra234-p3768-0000+p3767-0005-dynamic.dtbo`)
4. UEFI passes the merged, final DTB to the Linux kernel via the ARM64 boot
   protocol (`x0` = DTB physical address)
5. Linux kernel uses the DT to discover and bind drivers

You can inspect the live device tree on a running board:

```bash
# Dump the live DT to a readable DTS file
dtc -I fs -O dts /proc/device-tree > /tmp/live.dts 2>/dev/null

# Search for a specific node (e.g., I2C buses)
grep -A 5 'i2c@' /tmp/live.dts

# Verify DTBO application
cat /proc/device-tree/nvidia,dtb-overlays 2>/dev/null
```

---

## 8. Writing a Custom Device Tree Overlay

Device tree overlays (DTBOs) are the correct way to add or modify hardware
descriptions without forking the full upstream DTB.

### Overlay file format

```c
/dts-v1/;
/plugin/;

/* Target the root node of the base DTB */
&{/} {
    /* Example: add a fixed voltage regulator */
    vdd_3v3_sensor: regulator-sensor {
        compatible = "regulator-fixed";
        regulator-name = "vdd-3v3-sensor";
        regulator-min-microvolt = <3300000>;
        regulator-max-microvolt = <3300000>;
        gpio = <&gpio_aon TEGRA234_AON_GPIO(CC, 0) GPIO_ACTIVE_HIGH>;
        enable-active-high;
        regulator-always-on;
    };
};

/* Example: add a custom I2C device on I2C bus 1 */
&gen1_i2c {
    /* I2C bus 1 alias — see tegra234-p3768-0000+p3767-0005-nv-super.dtb */
    my_sensor@48 {
        compatible = "my-vendor,my-sensor";
        reg = <0x48>;
        vdd-supply = <&vdd_3v3_sensor>;
    };
};
```

### Compile the overlay

```bash
# Install DTC
sudo apt-get install device-tree-compiler

# Compile .dts to .dtbo
dtc -I dts -O dtb -o my-overlay.dtbo \
    -@ my-overlay.dts

# Verify the output
dtc -I dtb -O dts my-overlay.dtbo | head -50
```

The `-@` flag is required to preserve phandle symbols (labels like `&gen1_i2c`)
allowing overlay merging at runtime.

---

## 9. Applying an Overlay at Build Time

The clean way to include a custom overlay in this BSP is via a recipe in
`meta-physical-ai/`.

### 9.1 Create the recipe

```
meta-physical-ai/
└── recipes-bsp/
    └── device-tree/
        ├── my-overlay.dts            ← your DTS source
        └── tegra-device-tree_%.bbappend
```

**`my-overlay.dts`**: Your overlay source file (see Section 8).

**`tegra-device-tree_%.bbappend`**:

```bitbake
FILESEXTRAPATHS:prepend := "${THISDIR}:"

SRC_URI:append = " file://my-overlay.dts"

COMPATIBLE_MACHINE = "jetson-orin-nano-devkit-nvme"

do_compile:append() {
    dtc -I dts -O dtb -o ${B}/my-overlay.dtbo \
        -@ ${WORKDIR}/my-overlay.dts
}

do_install:append() {
    install -d ${D}${nonarch_base_libdir}/firmware/tegra/
    install -m 0644 ${B}/my-overlay.dtbo \
        ${D}${nonarch_base_libdir}/firmware/tegra/my-overlay.dtbo
}

FILES:${PN}:append = " ${nonarch_base_libdir}/firmware/tegra/my-overlay.dtbo"
```

### 9.2 Register the overlay with UEFI Boot Config

Add to `meta-physical-ai/recipes-bsp/tegra-configs/tegra-bootconfig_%.bbappend`:

```bitbake
# Add your overlay to the list written into A_BOOTCONFIG / B_BOOTCONFIG
TEGRA_DTBO_FILES:append = " my-overlay.dtbo"
```

> `meta-tegra` will then include `my-overlay.dtbo` in the boot configuration
> partition and UEFI will apply it at every boot.

### 9.3 Rebuild

```bash
./build.sh --rootfs rw --no-dm-verity
./flash.sh
```

---

## 10. Debugging Device Tree Issues

### Boot failure (kernel panic / no console)

Kernel DT errors usually produce early boot messages before the console is up.
Connect the serial console (`screen /dev/ttyACM0 115200`) to see MB1/UEFI/kernel
output.

Common DT-related panics:
- `OF: fdt: Unrecognized dtb devicetree` — wrong DTB written to QSPI
- `clocksource: Switched to clocksource arch_sys_counter` followed by hang —
  often a missing or incorrect CPU DT node

### Wrong DTB flashed

```bash
# On the board, dump the in-memory DTB
mkdir -p /tmp/dt
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
cat /sys/firmware/fdt | dtc -I dtb -O dts - > /tmp/dt/live.dts

# Check the model string
grep 'model =' /tmp/dt/live.dts
# model = "NVIDIA Jetson Orin Nano Developer Kit";
```

### Missing peripheral

```bash
# Check if a node exists and is enabled
grep -A3 'my_sensor' /tmp/dt/live.dts

# Check that the I2C bus is probing the address
i2cdetect -y 1    # bus 1 = gen1_i2c
```

### Overlay not applied

```bash
# List overlays that UEFI applied
cat /proc/device-tree/chosen/overlay-names 2>/dev/null | tr '\0' '\n'
```

If your overlay is missing from the list, check:
1. The `.dtbo` file is present in `A_BOOTCONFIG` QSPI partition
2. The overlay name is in `extlinux.conf` / UEFI boot config
3. Run `./flash.sh` to re-flash after build changes

---

## 11. Reference

| Resource | Location |
|---|---|
| SoC TRM | [Tegra234 TRM (NVIDIA Developer)](https://developer.nvidia.com/embedded/downloads) |
| Module datasheet | P3767 Datasheet / Design Guide |
| meta-tegra machine conf | `meta-tegra/conf/machine/jetson-orin-nano-devkit-nvme.conf` |
| Flash partition XML | `flash-artifacts/jetson-orin-nano-devkit-nvme/flash.xml.in` (after extraction) |
| External partition XML | `flash-artifacts/jetson-orin-nano-devkit-nvme/external-flash.xml.in` |
| DTBFILE variable | Set in machine conf, substituted into `flash.xml.in` at flash time |
| live DT on board | `/proc/device-tree/` (sysfs), `/sys/firmware/fdt` (raw blob) |
| Jetson Linux DT docs | [Jetson Linux Developer Guide — Flashing Support](https://docs.nvidia.com/jetson/archives/r36.4/DeveloperGuide/SD/FlashingSupport.html) |
