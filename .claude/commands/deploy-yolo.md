---
description: Deploy a YOLO detection model to CVAT auto-annotation (interactive)
---

You are helping a teammate deploy their own YOLO **detection** model as a CVAT
auto-annotation function. All the heavy lifting is done by the script
`serverless/pytorch/ultralytics/add_yolo_model.sh`. Your job is to collect the
inputs conversationally, sanity-check them, run the script, and report the
result.

## Steps

1. **Greet briefly and collect these inputs** (ask for any not already provided
   in the user's message: `$ARGUMENTS`):
   - **Weights path** — absolute path to the `.pt` file on THIS server.
     If the user only has it locally, tell them to copy it over first:
     `scp /local/path/best.pt <user>@<server>:/home/<user>/` and give you the
     resulting server path.
   - **Display name** — what shows in the CVAT Models tab, e.g. "Road Defects".
   - **Slug** — short id, lowercase letters/digits/`-`/`_`, e.g. `road_defects`.
     Offer to derive it from the display name.
   - **Class names** — comma-separated. ⚠️ **CRITICAL: the order MUST match the
     model's training class order** (the `names:` list in the training
     `data.yaml`), or predictions will get the wrong labels. Explicitly confirm
     the order with the user before proceeding.
   - **Threshold** (optional) — confidence cutoff, default `0.25`.

2. **Confirm** the collected values back to the user in a short summary and get
   a yes before running.

3. **Run the script** from the repo root:
   ```
   serverless/pytorch/ultralytics/add_yolo_model.sh \
     --weights <weights> --name "<name>" --slug <slug> \
     --classes <c1,c2,...> [--threshold <t>]
   ```
   - The first deploy of any model pulls PyTorch and takes ~10–15 min. Tell the
     user to expect that; don't interrupt it.
   - If the script errors that the **slug already exists**, ask whether they
     want a different slug or to replace that existing model (re-run with
     `--force` only if they confirm — it replaces ONLY that one model, others
     are untouched).
   - If the script prints a **nuctl not found** message, relay the install
     commands it shows.

4. **Report the result**: on success, tell them to refresh the CVAT **Models**
   tab — the model appears as the display name. Then in a task:
   *Actions → Automatic annotation → pick the model → map labels → Annotate*.
   Remind them to eyeball the first run to confirm class labels are correct (the
   real test of class-order).

## Notes

- This is CPU + detection only by design.
- Deploying a new model never disrupts already-running models (each gets its own
  auto-assigned port); concurrent deploys are serialized by the script.
- Do not hand-edit nuclio state or restart the `nuclio` container unless the
  script's health-check explicitly tells you to.
