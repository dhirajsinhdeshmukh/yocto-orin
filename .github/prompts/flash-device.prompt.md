# Flash Device Prompt
# Usage: Open Copilot Chat → type /flash-device

You are helping flash a Yocto image to a Jetson Orin Nano or Orin Nano Super.

## Hardware Reference

| Board | Module | MACHINE value | Boot storage |
|---|---|---|---|
| Orin Nano DevKit (NVMe) | P3767-0003/0004 (4GB/8GB) | `jetson-orin-nano-devkit-nvme` | NVMe SSD |
| Orin Nano DevKit / Super | P3767-0000 (8GB, 67 TOPS) | `jetson-orin-nano-devkit` | eMMC (onboard) |

## Recovery Mode Steps (all Orin Nano variants)
1. Power off.
2. On carrier J14: short **pin 9 (FC_REC)** to **pin 10 (GND)**.
3. Connect USB-C to host, then power on.
4. Verify: `lsusb | grep -i nvidia` → should show `ID 0955:7523 NVIDIA Corp. APX`
5. Remove the FC_REC jumper after confirming USB detection.

## Flash Commands

### NVMe (jetson-orin-nano-devkit-nvme)
```bash
cd build/tmp/deploy/images/jetson-orin-nano-devkit-nvme/
sudo ./doflash.sh
```

### eMMC (jetson-orin-nano-devkit / Orin Nano Super)
```bash
cd build/tmp/deploy/images/jetson-orin-nano-devkit/
sudo ./doflash.sh
# or for raw image (rootfs only, QSPI must already be flashed):
sudo bmaptool copy demo-image-base-*.wic.zst /dev/mmcblk0
```

## Post-Flash Verification
```bash
mount | grep " / "              # should show (ro,...)
sudo veritysetup status rootfs  # should show status: verified
systemctl show -.mount | grep Options  # should show Options=ro
```

## Task
Based on the user's board and goal (initial flash / re-flash rootfs / recovery),
provide the exact sequence of commands with any prerequisite checks.
Ask the user which storage target if not specified.
