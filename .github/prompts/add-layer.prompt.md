# Add Yocto Layer Prompt
# Usage: Open Copilot Chat → type /add-layer

You are helping add a new Yocto layer to this BSP project.

## Context
This project uses `kas` with layers pinned to commit SHAs in `kas/layers.yml`.
The Yocto release is scarthgap (5.0). Never use a branch name as `refspec`.

## Task
Add the layer the user requests by:

1. **Find the latest scarthgap SHA** for the layer's repository:
   ```bash
   git ls-remote <layer-url> refs/heads/scarthgap | cut -f1
   ```

2. **Check the repo's actual directory layout** before writing the layer key:
   ```bash
   git clone --depth 1 --branch scarthgap <layer-url> /tmp/layer-check
   ls /tmp/layer-check/
   ```
   - If `conf/layer.conf` is at the repo root → use `.:` as the layer key
   - If it's inside a subdirectory (e.g. `meta-oe/`) → use `meta-oe:` as the key

3. **Add the repo block** to `kas/layers.yml` under `repos:`:
   ```yaml
   <layer-name>:
     url: "<git-url>"
     refspec: <pinned-sha>
     layers:
       .:          # or <sublayer-name>: if it lives in a subdirectory
   ```

4. **Check `LAYERDEPENDS`** in the new layer's `conf/layer.conf` — any listed
   dependency layers must also be present in `kas/layers.yml`. Common ones:
   - `openembedded-layer` → needs `meta-openembedded` repo with `meta-oe` sublayer

5. **Add `LAYERDEPENDS`** to `meta-physical-ai/conf/layer.conf` if our custom
   layer depends on any recipe from the new layer.

6. **Validate YAML**:
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('kas/layers.yml'))" && echo OK
   ```

7. **Confirm `LAYERSERIES_COMPAT`** — the new layer must declare `scarthgap`
   in its `conf/layer.conf`. Check the layer's `layer.conf` in its repo.

## Output
Return the exact diff to `kas/layers.yml` with the new repo block and any
needed changes to `meta-physical-ai/conf/layer.conf`.
