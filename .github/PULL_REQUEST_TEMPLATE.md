## Summary
<!-- What does this PR do? One paragraph max. -->

## Type of Change
- [ ] New layer / package added
- [ ] Security hardening change
- [ ] Layer pin update (SHA bump)
- [ ] Custom recipe (meta-physical-ai)
- [ ] Build script / Docker change
- [ ] Documentation

## Checklist

### All PRs
- [ ] `python3 -c "import yaml; yaml.safe_load(open('kas-project.yml'))"` passes
- [ ] All new layers in `kas/layers.yml` use a pinned **commit SHA**, not a branch name
- [ ] No keys, passwords, or secrets added

### Image / Layer Changes
- [ ] `kas shell kas-project.yml -c "bitbake-layers show-layers"` succeeds
- [ ] `LAYERSERIES_COMPAT` includes `scarthgap` in any new `layer.conf`
- [ ] New recipes use `:` variable operators (`FILES:${PN}`, `RDEPENDS:${PN}`)
- [ ] Layer paths in `kas/layers.yml` use `.` when the layer sits at the repo root (not named subdir)
- [ ] Any new layer's `LAYERDEPENDS` are satisfied by existing entries in `kas/layers.yml`
- [ ] SDK package names use Yocto naming (`openssl-dev`, `curl-dev`, not `libssl-dev`, `libcurl-dev`)

### Security Changes
- [ ] `debug-tweaks` is NOT re-added
- [ ] `read-only-rootfs` IMAGE_FEATURE is preserved in production config
- [ ] dm-verity signing paths point to `${TOPDIR}/../keys/` (not hardcoded absolute paths)

### Recipe Changes
- [ ] `LICENSE` and `LIC_FILES_CHKSUM` are set
- [ ] systemd services use `inherit systemd`
- [ ] Runtime config files that need write access use `tmpfiles.d`

## Testing
<!-- Describe how this was tested. Minimum: kas config validation. Preferred: build + flash. -->
- [ ] Config validated (`kas check` / YAML parse)
- [ ] Bitbake dry-run (`bitbake -n <target>`)
- [ ] Full build
- [ ] Flashed to device and verified (`mount`, `veritysetup status`)
