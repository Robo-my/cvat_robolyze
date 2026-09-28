#!/usr/bin/env python3
"""Normalize any Ultralytics YOLO export into the layout CVAT imports cleanly.

    cvat-prepare-yolo-zip.py INPUT.zip|DIR [-o OUTPUT.zip] [--subset train]

Handles: flat images/ + labels/, Roboflow-style <subset>/images + <subset>/labels,
images/<subset>/ + labels/<subset>/, or a bare folder of images + .txt files.
Writes images/<subset>/… + labels/<subset>/… and a data.yaml with `names:` (dropping `nc:`),
and reports images without labels and labels without images.

The CVAT image itself is patched to accept the first two layouts (deploy/ec2/patches/), so this
is only needed for stranger inputs or when preparing files for a stock CVAT.
"""
import argparse, os, shutil, sys, tempfile, zipfile

IMG_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tif", ".tiff"}


def load_names(root):
    """Read class names from data.yaml / obj.names, preserving id order."""
    for cfg in ("data.yaml", "data.yml"):
        p = os.path.join(root, cfg)
        if not os.path.isfile(p):
            continue
        try:
            import yaml
            data = yaml.safe_load(open(p, encoding="utf-8")) or {}
        except Exception as e:  # noqa: BLE001
            sys.exit(f"cannot parse {p}: {e}")
        names = data.get("names")
        if isinstance(names, dict):
            return [names[k] for k in sorted(names, key=int)]
        if isinstance(names, list):
            return names
    p = os.path.join(root, "obj.names")
    if os.path.isfile(p):
        return [l.strip() for l in open(p, encoding="utf-8") if l.strip()]
    return None


def collect(root):
    """Map image path -> label path, whatever the layout."""
    images, labels = {}, {}
    for dirpath, _, filenames in os.walk(root):
        for fn in filenames:
            stem, ext = os.path.splitext(fn)
            full = os.path.join(dirpath, fn)
            if ext.lower() in IMG_EXT:
                images.setdefault(stem, full)
            elif ext.lower() == ".txt" and fn not in ("train.txt", "valid.txt", "val.txt", "test.txt"):
                labels.setdefault(stem, full)
    return images, labels


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("-o", "--output")
    ap.add_argument("--subset", default="train")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="cvat-yolo-")
    try:
        if os.path.isdir(args.input):
            root = args.input
        else:
            root = os.path.join(tmp, "in")
            with zipfile.ZipFile(args.input) as z:
                z.extractall(root)
        # a single top-level folder in the zip is the real root
        entries = [e for e in os.listdir(root) if not e.startswith("__MACOSX")]
        if len(entries) == 1 and os.path.isdir(os.path.join(root, entries[0])):
            root = os.path.join(root, entries[0])

        names = load_names(root)
        if not names:
            sys.exit("no class names found (data.yaml `names:` or obj.names) - add one and retry")
        images, labels = collect(root)
        if not images:
            sys.exit("no images found")

        out_root = os.path.join(tmp, "out")
        img_dir = os.path.join(out_root, "images", args.subset)
        lbl_dir = os.path.join(out_root, "labels", args.subset)
        os.makedirs(img_dir); os.makedirs(lbl_dir)
        missing = []
        for stem, src in sorted(images.items()):
            shutil.copy(src, os.path.join(img_dir, os.path.basename(src)))
            lbl = labels.get(stem)
            if lbl:
                shutil.copy(lbl, os.path.join(lbl_dir, stem + ".txt"))
            else:
                open(os.path.join(lbl_dir, stem + ".txt"), "w").close()
                missing.append(stem)
        orphan = sorted(set(labels) - set(images))

        with open(os.path.join(out_root, "data.yaml"), "w", encoding="utf-8") as f:
            f.write("names:\n")
            for i, n in enumerate(names):
                f.write(f"  {i}: {n}\n")
            f.write("path: .\n")
            f.write(f"{args.subset}: {os.path.join('images', args.subset)}\n")

        out = args.output or (os.path.splitext(os.path.abspath(args.input))[0] + "_cvat.zip")
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for dirpath, _, filenames in os.walk(out_root):
                for fn in filenames:
                    p = os.path.join(dirpath, fn)
                    z.write(p, os.path.relpath(p, out_root))

        print(f"wrote {out}")
        print(f"  images: {len(images)}  labels: {len(labels)}  classes: {len(names)}")
        if missing:
            print(f"  WARNING: {len(missing)} image(s) had no label file (empty ones written): "
                  f"{', '.join(missing[:5])}{' …' if len(missing) > 5 else ''}")
        if orphan:
            print(f"  WARNING: {len(orphan)} label file(s) had no image and were skipped: "
                  f"{', '.join(orphan[:5])}{' …' if len(orphan) > 5 else ''}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
