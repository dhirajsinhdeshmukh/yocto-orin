# GitHub Copilot Instructions — Yocto Orin Nano BSP

You are assisting with a **production-grade Yocto BSP** for NVIDIA Jetson Orin Nano.
Learn this project's structure before suggesting changes.

## Project Context

- **Build tool:** `kas` (Python wrapper around Yocto/bitbake) — config in `kas-project.yml`; install via `pip install -r requirements.txt` into `.venv`
- **Target hardware:** NVIDIA Jetson Orin Nano DevKit (NVMe boot) and Orin Nano Super (eMMC)
- **Yocto release:** scarthgap (5.0) — all layers pinned to specific commit SHAs
- **Distro:** `poky` (standard OE-core) — `meta-tegra` provides the MACHINE, not a custom distro
- **Security posture:** dm-verity signed rootfs + read-only rootfs (systemd-enforced)
- **Custom layer:** `meta-physical-ai/` — our own recipes, always edit here for custom logic

## Reference Docs

- `docs/GUIDE.md` — repo map, flashing workflow, and common commands
- `docs/RECIPES.md` — recipe and layer development guide
- `docs/CACHING.md` — cache layout, cache effectiveness, and cleanup rules
- `docs/OTA.md` — A/B update architecture and RAUC notes
- `docs/DEVICE-TREE.md` — DTB and partition-layout reference

## File Ownership Rules

| To do this | Edit this file | Key variable |
|---|---|---|
| Add package to Jetson rootfs | `kas/image-packages.yml` | `IMAGE_INSTALL:append` |
| Add lib/header to SDK sysroot | `kas/sdk.yml` | `TOOLCHAIN_TARGET_TASK:append` |
| Add SDK host tool | `kas/sdk.yml` | `TOOLCHAIN_HOST_TASK:append` |
| Add a new community layer | `kas/layers.yml` | new `repos:` block |
| Change dm-verity / cache / tuning | `kas/local-conf.yml` | see file |
| Change MACHINE or distro | `kas-project.yml` | `machine:` / `distro:` — distro is always `poky` |
| Add custom recipe or service | `meta-physical-ai/recipes-*/` | `.bb` / `.bbappend` |
| Add image target recipe | `meta-physical-ai/recipes-core/images/` | `demo-image-base.bb` |

## Coding Conventions

### Yocto Recipes (.bb files)
- Always include `LICENSE` and `LIC_FILES_CHKSUM`
- Use `RDEPENDS:${PN}` not `RDEPENDS_${PN}` (scarthgap uses `:` operator)
- Use `FILES:${PN}` not `FILES_${PN}`
- Use `do_install:append()` not `do_install_append()`
- Prefer `install -m <mode> <src> <dst>` over `cp` in `do_install`
- systemd service recipes must `inherit systemd` and set `SYSTEMD_SERVICE:${PN}`

### kas Configuration
- **Always pin layers to a commit SHA** — never a branch name in `refspec:`
- kas `local_conf_header` keys must be unique across all included files
- Use `?=` for defaults that `build.sh` can override; use `=` for hard requirements
- Run `python3 -c "import yaml; yaml.safe_load(open('kas-project.yml'))"` to validate

### Security Rules
- **Never suggest committing keys** — `keys/` is in `.gitignore`
- **Never re-add `debug-tweaks`** to image features in production configs
- `IMAGE_FEATURES:remove = "read-only-rootfs"` is only valid for `--rootfs rw` dev builds
- dm-verity must be disabled explicitly via `build.sh --no-dm-verity`, not by editing kas files

### Shell Scripts (build.sh, kas-docker.sh)
- Scripts use `set -euo pipefail` — maintain this
- New options must follow the `--long-flag VALUE` convention
- Inject temporary settings via the kas override YAML merge (`kas-project.yml:${SCRIPT_DIR}/tmp/kas-override.yml`), never by mutating `kas-project.yml` at runtime
- Override files **must live inside the repo tree** (`${SCRIPT_DIR}/tmp/`) — kas 5.2+ rejects concatenating files from different VCS roots (e.g. `/tmp`)
- The generated override must **not** include an `includes:` stanza re-pointing at `kas-project.yml` — that would be a circular double-load
- `build.sh` auto-activates `.venv/bin/activate` when `kas` is not already on `PATH`
- Prefer the repo's `./flash.sh` wrapper for flashing guidance; only drop down
  to `doflash.sh` when working with already extracted artifacts on purpose

## Layer Architecture

```
meta-physical-ai/               ← our customizations
  recipes-core/images/          ← demo-image-base.bb (the top-level image target)
  recipes-core/systemd/         ← read-only rootfs drop-in (always active)
  recipes-core/overlayfs-setup/ ← volatile overlay (only when ROOTFS_MODE=overlayfs)
```

### Layer path convention in kas/layers.yml
When a community layer repo has its `conf/layer.conf` at the **repo root** (not in a
named subdirectory), the kas layer key must be `.`, not the repo name:
```yaml
meta-tegra:
  url: "..."
  refspec: <sha>
  layers:
    .:          # ← correct: layer.conf is at repo root
    # NOT meta-tegra:  ← wrong if there is no meta-tegra/ subdirectory
```
Always verify with `ls <cloned-repo>/` before assuming a subdirectory exists.

### SDK package naming
Use **Yocto/OE package names**, not Debian package names:
- `openssl-dev` not `libssl-dev`
- `curl-dev` not `libcurl-dev`
- `zlib-dev` not `zlib1g-dev`

When adding a new feature, create a recipe in `meta-physical-ai/` and wire it via
`IMAGE_INSTALL:append` in `kas/image-packages.yml`. Do not inline complex logic in
`local_conf_header`.

## Common Bitbake Commands (run via `kas shell kas-project.yml -c "<cmd>"`)

```bash
bitbake-layers show-layers              # verify all layers loaded
bitbake -s | grep <pattern>             # search available recipes
bitbake <recipe> -c listtasks           # list tasks for a recipe
bitbake <recipe> -c devshell            # interactive build shell
bitbake demo-image-base -c populate_sdk # build SDK installer
```
