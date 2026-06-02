# Ultralytics YOLO detection models for CVAT auto-annotation

Self-service deployment of custom **YOLO detection** models as CVAT/Nuclio
serverless functions. CPU + detection only.

## Quick start

Easiest: in Claude Code run `/deploy-yolo` and answer the prompts.

Or run the script directly:

```bash
serverless/pytorch/ultralytics/add_yolo_model.sh \
  --weights /path/to/best.pt \
  --name "Road Defects" \
  --slug road_defects \
  --classes cracks,potholes,raveling,sw \
  [--threshold 0.25] [--force]
```

- Copy your `.pt` to the server first (`scp ...`), then point `--weights` at it.
- ⚠️ `--classes` order **must** match the model's training class order (the
  `names:` list in the training `data.yaml`), or predictions get wrong labels.
- First deploy of any model builds a docker image and pulls PyTorch (~10–15 min);
  later models reuse the cache (~30 s).
- After it reports `ready`, refresh the CVAT **Models** tab, then in a task:
  _Actions → Automatic annotation_.

## Layout

- `_template/` — `function.yaml.tmpl` + generic `main.py` the script renders from.
- `add_yolo_model.sh` — generator + deployer (handles nuclio project, alpine
  helper image, deploy flags, collision guard, health check).
- `<slug>/nuclio/` — generated per model: `function.yaml`, `main.py`, `model.pt`.
- `yolo11_robolyze/` — example output (a 4-class road-defect model). Its weights
  (`*.pt`) are gitignored; drop your own `yolo11n.pt` there if reproducing, or
  just use the script to generate a fresh model dir.
