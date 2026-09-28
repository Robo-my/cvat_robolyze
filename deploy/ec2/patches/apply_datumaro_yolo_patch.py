#!/usr/bin/env python3
"""Apply the Robolyze datumaro YOLO reader fixes in place (the CVAT image has no `patch` binary).

Fixes two upstream bugs that break Ultralytics YOLO imports (cvat#8958, cvat#8973 - both open):
  1. `nc:` in data.yaml is read as a subset -> "'int' object is not iterable"
  2. a flat `images/<file>` layout is rejected as "Malformed folder structure"

Idempotent: re-running is a no-op. Exits non-zero if an expected code block is missing, which is
the signal that a datumaro bump changed these functions and the fix must be re-checked upstream.
See patches/datumaro-yolo-ultralytics.patch for the same change as a unified diff.
"""
import os
import sys

import datumaro.plugins.data_formats.yolo as yolo_pkg

YOLO_DIR = os.path.dirname(yolo_pkg.__file__)

EDITS = {
    "format.py": [
        (
            'RESERVED_CONFIG_KEYS = YoloPath.RESERVED_CONFIG_KEYS + [\n'
            '        "path",\n        "kpt_shape",\n        "flip_idx",\n    ]',
            'RESERVED_CONFIG_KEYS = YoloPath.RESERVED_CONFIG_KEYS + [\n'
            '        "path",\n        "kpt_shape",\n        "flip_idx",\n'
            '        # Standard Ultralytics key for the number of classes. Without this it is read\n'
            '        # as a subset whose image list is an int -> "\'int\' object is not iterable".\n'
            '        "nc",\n    ]',
        ),
    ],
    "base.py": [
        (
            "        return [k for k in self._config if k not in self.RESERVED_CONFIG_KEYS]",
            "        # A subset value is a path (str) or a list of paths; any other type (e.g. a\n"
            "        # stray scalar like `nc: 5`) is config metadata, not a subset.\n"
            "        return [\n"
            "            k\n"
            "            for k, v in self._config.items()\n"
            "            if k not in self.RESERVED_CONFIG_KEYS and isinstance(v, (str, list))\n"
            "        ]",
        ),
        (
            "        rel_image_path = osp.relpath(image_path, self._path)\n"
            "        split_rel_path = rel_image_path.split(osp.sep, 2)\n"
            "        if (\n"
            "            len(split_rel_path) < 3\n",
            "        rel_image_path = osp.relpath(image_path, self._path)\n"
            "        split_rel_path = rel_image_path.split(osp.sep, 2)\n"
            "        if (\n"
            "            len(split_rel_path) == 2\n"
            "            and split_rel_path[0] == YoloUltralyticsPath.IMAGES_FOLDER_NAME\n"
            "        ):\n"
            "            # Flat layout: images/<file>.ext -> labels/<file>.txt. Datasets not produced\n"
            "            # by CVAT often have no <subset> level.\n"
            "            return osp.join(\n"
            "                self._path,\n"
            "                YoloUltralyticsPath.LABELS_FOLDER_NAME,\n"
            "                osp.splitext(split_rel_path[1])[0] + YoloUltralyticsPath.LABELS_EXT,\n"
            "            )\n"
            "        if (\n"
            "            len(split_rel_path) < 3\n",
        ),
        (
            "        parts = split_path(path)\n"
            "        if 2 < len(parts) and not osp.isabs(path):\n"
            "            path = osp.join(*parts[2:])  # pylint: disable=no-value-for-parameter\n"
            "        return osp.splitext(path)[0]",
            "        parts = split_path(path)\n"
            "        if 2 < len(parts) and not osp.isabs(path):\n"
            "            path = osp.join(*parts[2:])  # pylint: disable=no-value-for-parameter\n"
            "        elif (\n"
            "            len(parts) == 2\n"
            "            and parts[0] == YoloUltralyticsPath.IMAGES_FOLDER_NAME\n"
            "            and not osp.isabs(path)\n"
            "        ):\n"
            "            # Flat layout (see _get_labels_path_from_image_path): strip the \"images/\"\n"
            "            # prefix so item ids still match CVAT frame names.\n"
            "            path = parts[1]\n"
            "        return osp.splitext(path)[0]",
        ),
    ],
}


def main() -> int:
    for filename, edits in EDITS.items():
        path = os.path.join(YOLO_DIR, filename)
        src = open(path, encoding="utf-8").read()
        original = src
        for old, new in edits:
            if new in src:
                continue  # already applied
            if old not in src:
                print(f"ERROR: {filename}: expected code block not found:\n{old[:120]}...", file=sys.stderr)
                return 1
            src = src.replace(old, new, 1)
        if src != original:
            open(path, "w", encoding="utf-8").write(src)
            print(f"patched {path}")
        else:
            print(f"already patched {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
