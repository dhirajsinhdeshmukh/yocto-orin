# Build Cache Guide

How caching works in this repo, what reduces cache effectiveness, and when to
remove build state instead of fighting stale artifacts.

---

## Overview

This repo uses the standard Yocto cache split:

- `downloads/` stores fetched source tarballs and git mirrors (`DL_DIR`)
- `sstate-cache/` stores reusable task output (`SSTATE_DIR`)
- `build/tmp/` is the active per-build workspace (`TMPDIR`)

Those paths are configured in [kas/local-conf.yml](../kas/local-conf.yml):

```bitbake
DL_DIR ?= "${TOPDIR}/../downloads"
SSTATE_DIR ?= "${TOPDIR}/../sstate-cache"
```

That means caches live at the repo root, outside `build/`, so they survive
across repeated `kas build` runs.

---

## What Each Directory Does

| Path | Yocto variable | What it contains | Keep it? |
|---|---|---|---|
| `downloads/` | `DL_DIR` | Source archives, git mirrors, fetched upstream content | Yes |
| `sstate-cache/` | `SSTATE_DIR` | Reusable task outputs keyed by task signatures | Yes |
| `build/tmp/` | `TMPDIR` | Active workdirs, stamps, logs, deploy output, pkgdata | Disposable |
| `flash-artifacts/` | n/a | Extracted tegraflash bundle created by `flash.sh` | Disposable |
| `tmp/` | n/a | Temporary kas override YAMLs created by `build.sh` | Disposable |

The important distinction is:

- `downloads/` avoids re-fetching sources
- `sstate-cache/` avoids rebuilding completed tasks
- `build/tmp/` is not a long-term cache; it is the live build workspace

---

## How Cache Reuse Works Here

Yocto decides whether a task can be reused from `sstate-cache/` by comparing
task signatures. If the signature still matches, the task is restored from
sstate instead of being rebuilt.

In this repo, good cache reuse usually happens when these stay stable:

- the pinned layer SHAs in `kas/layers.yml`
- the target `MACHINE`
- rootfs mode and dm-verity mode passed through `build.sh`
- recipe metadata in `meta-physical-ai/`
- important `local.conf` inputs from [kas/local-conf.yml](../kas/local-conf.yml)
- the host toolchain / Yocto version combination

You should expect lower cache reuse when you intentionally change build mode,
security settings, or image content. That is normal and not a cache failure.

---

## What Makes Cache Less Effective

These are the common ways to hurt cache hit rate in this repo:

- Changing `--machine`, `--rootfs`, or `--dm-verity` between builds.
- Editing `kas/local-conf.yml`, especially image features, signing settings, or
  storage-layout values.
- Editing recipes, `.bbappend` files, patches, service files, or package lists.
- Bumping layer SHAs in `kas/layers.yml`.
- Forcing tasks with `-f`, `-c clean`, or `-c cleansstate`.
- Switching branches with very different metadata.
- Deleting `build/tmp/`, `sstate-cache/`, or `downloads/`.

In short: cache effectiveness improves when metadata stays stable. It drops
when task inputs change, which is usually the correct behavior.

---

## When To Remove State Artifacts

Most build problems do **not** require deleting everything. Start as narrowly as
possible.

### Remove only recipe work first

Use this when one recipe seems stuck, partially rebuilt, or out of sync:

```bash
kas build --target <recipe> -c clean kas-project.yml
kas build --target <recipe> -c cleansstate kas-project.yml
```

Use:

- `clean` to remove that recipe's work output from `build/tmp/`
- `cleansstate` to also invalidate its reusable sstate output

### Remove `build/tmp/`

Use this when:

- you changed a lot of config and want a fresh workspace
- deploy artifacts in `build/tmp/deploy/` are stale or confusing
- you suspect incremental workspace corruption
- you want to keep `downloads/` and `sstate-cache/` but rebuild the workspace

Command:

```bash
rm -rf build/tmp
```

This is the most common "freshen the build" reset and usually the right first
full cleanup.

### Remove `sstate-cache/`

Use this only when:

- bad sstate is being reused across repeated builds
- multiple branches or machines polluted a shared cache badly
- you want to measure a true cold rebuild
- a specific task keeps restoring broken output from cache

Command:

```bash
rm -rf sstate-cache
```

This is expensive. You will keep downloads, but most tasks will rebuild.

### Remove `downloads/`

Use this rarely, for example when:

- an upstream tarball or git mirror is corrupt
- a fetch artifact is incomplete
- upstream content was replaced and you need a clean refetch

Prefer removing only the broken source first. Full wipe:

```bash
rm -rf downloads
```

This causes fresh network fetches on the next build.

### Remove `flash-artifacts/`

Use this when you want to discard an extracted flash bundle manually. Normally
you do not need to do this because `flash.sh` recreates it as needed.

```bash
rm -rf flash-artifacts
```

---

## Recommended Cleanup Order

When a build behaves strangely, use this order:

1. Re-run the failing task and inspect logs in `build/tmp/work/.../temp/`.
2. Clean only the affected recipe with `-c clean`.
3. Escalate to `-c cleansstate` for that recipe.
4. Remove `build/tmp/` if the workspace or deploy outputs look stale.
5. Remove `sstate-cache/` only if you strongly suspect bad cache reuse.
6. Remove `downloads/` only for fetch corruption or forced refetch cases.

This keeps the fast paths fast.

---

## Commands You Will Actually Use

```bash
# Show recent task logs
find build/tmp/work -name "log.do_*" -type f | tail -20

# Clean one recipe's workdir
kas build --target <recipe> -c clean kas-project.yml

# Clean one recipe's workdir and sstate
kas build --target <recipe> -c cleansstate kas-project.yml

# Clean one recipe's workdir, sstate, and downloaded source
kas build --target <recipe> -c cleanall kas-project.yml

# Rebuild after wiping only the active workspace
rm -rf build/tmp
./build.sh --rootfs rw --no-dm-verity

# Full cache reset
rm -rf build/tmp sstate-cache downloads
```

---

## Repo-Specific Notes

- `build.sh` writes temporary kas overrides under repo-local `tmp/`, not
  system `/tmp/`, because kas 5.2+ requires concatenated config files to be in
  the same repository.
- `flash.sh` reads staged flash bundles from `build/tmp/deploy/images/...`, so
  deleting `build/tmp/` removes those deploy artifacts too.
- `./build.sh --flash-artifacts-only` is useful when the image build itself is
  already good and you only need to refresh the staged tegraflash bundle.

---

## Quick Rule Of Thumb

- Keep `downloads/` unless fetch data is bad.
- Keep `sstate-cache/` unless cached task output is bad.
- Delete `build/tmp/` when you want a fresh workspace.
- Use `clean` and `cleansstate` before doing big deletes.
