#!/bin/bash
# Build cvat/server:dev = official cvat/server:<base> + Robolyze patches, verify it, keep a rollback tag.
# Usage: deploy/ec2/build-server-image.sh [base-version]   (default: CVAT_VERSION in .env, else v2.74.0)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="${1:-${CVAT_BASE:-v2.74.0}}"
CTX="$(mktemp -d)"; trap 'rm -rf "$CTX"' EXIT

cp "$REPO/cvat/apps/engine/cache.py" "$CTX/"
cp "$REPO/deploy/ec2/patches/apply_datumaro_yolo_patch.py" "$CTX/"
cp "$REPO/cvat/settings/robolyze.py" "$CTX/"
cp "$REPO/deploy/ec2/docker/Dockerfile.server" "$CTX/Dockerfile"

echo ">> pulling cvat/server:$BASE"
docker pull -q "cvat/server:$BASE"

if docker image inspect cvat/server:dev >/dev/null 2>&1; then
    prev="cvat/server:$(docker run --rm --entrypoint python3 cvat/server:dev -c 'import cvat;print(cvat.__version__)' 2>/dev/null || echo unknown)-patched-prev"
    docker tag cvat/server:dev "$prev"; echo ">> previous image kept as $prev"
fi

echo ">> building (base $BASE)"
docker build -q --build-arg "CVAT_BASE=$BASE" -t cvat/server:dev "$CTX"

echo ">> verifying"
docker run --rm -u root -e DJANGO_SECRET_KEY=build-check --entrypoint python3 cvat/server:dev -c "import cvat; print('version', cvat.__version__)"
docker run --rm -u root -e DJANGO_SECRET_KEY=build-check --entrypoint python3 cvat/server:dev -c "
from datumaro.plugins.data_formats.yolo.format import YoloUltralyticsPath as P
from datumaro.plugins.data_formats.yolo.base import YoloUltralyticsDetectionBase as B
import inspect
print('reserved keys:', P.RESERVED_CONFIG_KEYS)
print('flat layout supported:', 'Flat layout' in inspect.getsource(B._get_labels_path_from_image_path))
print('export lock fix:', 'timeout=600' in open('/opt/cvat/cvat/apps/engine/cache.py').read())
import os; os.environ['DJANGO_SETTINGS_MODULE']='cvat.settings.robolyze'
from django.conf import settings
print('email backend:', settings.EMAIL_BACKEND)"
echo ">> cvat/server:dev ready. Apply with: sudo systemctl restart cvat  (or /opt/cvat/cvat-start.sh)"
