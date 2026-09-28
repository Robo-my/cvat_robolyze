#!/bin/bash
# Checks: CVAT API up, all nuclio functions ready, each model invokable via CVAT's own LambdaGateway.
set -uo pipefail
OUT=/var/log/cvat-health.last
fail=0; msgs=()
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Host: '"$(grep ^CVAT_HOST= /home/ubuntu/cvat_robolyze/.env | cut -d= -f2)" http://localhost:8080/api/server/about)
[ "$code" = 200 ] && msgs+=("api ok") || { msgs+=("API FAIL http=$code"); fail=1; }
res=$(docker exec -i -w /opt/cvat cvat_server python3 - <<'PY' 2>&1 | grep -v -i -E "warn|^\s*$"
import base64, io, os, sys
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "cvat.settings.production")
import django; django.setup()
from PIL import Image
from cvat.apps.lambda_manager.views import LambdaGateway
buf = io.BytesIO(); Image.new("RGB", (64, 64), (128, 128, 128)).save(buf, "JPEG")
img = base64.b64encode(buf.getvalue()).decode()
gw = LambdaGateway(); funcs = list(gw.list()); bad = 0
for f in funcs:
    try:
        gw.invoke(f, {"image": img, "threshold": 0.5}); print(f"model ok {f.id}")
    except Exception as e:
        bad += 1; print(f"MODEL FAIL {f.id}: {type(e).__name__}: {str(e)[:120]}")
print(f"models {len(funcs)-bad}/{len(funcs)} ok")
sys.exit(1 if bad or not funcs else 0)
PY
); echo "$res" | grep -q "^models [0-9]*/[0-9]* ok" && ! echo "$res" | grep -q "MODEL FAIL" && ! echo "$res" | grep -q "^models 0/" || fail=1
msgs+=("$res")
# image patches must survive rebuilds (datumaro YOLO import fixes + export lock timeout)
patch=$(docker exec cvat_server python3 -c "
from datumaro.plugins.data_formats.yolo.format import YoloUltralyticsPath as P
from datumaro.plugins.data_formats.yolo.base import YoloUltralyticsDetectionBase as B
import inspect
ok = 'nc' in P.RESERVED_CONFIG_KEYS and 'Flat layout' in inspect.getsource(B._get_labels_path_from_image_path)
ok = ok and 'timeout=600' in open('/opt/cvat/cvat/apps/engine/cache.py').read()
print('image patches ok' if ok else 'IMAGE PATCHES MISSING (rebuild with deploy/ec2/build-server-image.sh)')" 2>&1 | tail -1)
msgs+=("$patch"); case "$patch" in *MISSING*|*Error*|*error*) fail=1;; esac

[ -f /var/lib/cvat-backup/NAS_PENDING ] && msgs+=("WARNING: NAS unreachable at last backup; local copies pending: $(cat /var/lib/cvat-backup/NAS_PENDING)")
{ echo "$(date -Is) status=$([ $fail = 0 ] && echo OK || echo FAIL)"; printf '%s\n' "${msgs[@]}"; } | tee $OUT
exit $fail
