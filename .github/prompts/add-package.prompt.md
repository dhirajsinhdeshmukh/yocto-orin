# Add Package to Image or SDK Prompt
# Usage: Open Copilot Chat → type /add-package

You are helping add a package to either the Jetson rootfs image or the cross-compile SDK.

## Context
- Rootfs packages → `kas/image-packages.yml` → `IMAGE_INSTALL:append`
- SDK host tools  → `kas/sdk.yml` → `TOOLCHAIN_HOST_TASK:append = " nativesdk-<name>"`
- SDK target libs → `kas/sdk.yml` → `TOOLCHAIN_TARGET_TASK:append = " <name>-dev"`
- Repo usage guide: `docs/GUIDE.md`

## Rules
- The leading space inside the quoted string is **required** by bitbake's append operator.
- Package names follow OpenEmbedded conventions (lowercase, hyphen-separated).
  Use **Yocto names, not Debian names**:
  - `openssl-dev` not `libssl-dev`
  - `curl-dev` not `libcurl-dev`
  - `zlib-dev` not `zlib1g-dev`
  - `nativesdk-cmake`, `nativesdk-python3` for SDK host tools
- For packages from extra layers (meta-oe, etc.), the layer must first be added
  to `kas/layers.yml` — prompt the user if that's missing.
- Never add debug packages (`gdb`, `valgrind`, `strace`) to the production
  `image-base:` block — add them only to the `image-debug:` block with a comment.

## Task
Based on what the user wants to add:
1. Determine: rootfs image, SDK host, or SDK target sysroot?
2. Find the correct recipe/package name (check `bitbake -s` output or OE layer index).
3. Add to the correct section in the correct file.
4. If the package requires a layer not yet in `kas/layers.yml`, say so explicitly.

## Output
Return the exact line(s) to add to the appropriate file.
