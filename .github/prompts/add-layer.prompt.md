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

2. **Add the repo block** to `kas/layers.yml` under `repos:`:
   ```yaml
   <layer-name>:
     url: "<git-url>"
     refspec: <pinned-sha>
     layers:
       <sublayer-name>:
   ```

3. **Add `LAYERDEPENDS`** to `meta-physical-ai/conf/layer.conf` if our custom
   layer depends on any recipe from the new layer.

4. **Validate YAML**:
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('kas/layers.yml'))" && echo OK
   ```

5. **Confirm `LAYERSERIES_COMPAT`** — the new layer must declare `scarthgap`
   in its `conf/layer.conf`. Check the layer's `layer.conf` in its repo.

## Output
Return the exact diff to `kas/layers.yml` with the new repo block and any
needed changes to `meta-physical-ai/conf/layer.conf`.
