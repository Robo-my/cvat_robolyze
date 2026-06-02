#!/bin/bash
# Generate + deploy a YOLO detection model as a CVAT/Nuclio serverless function.
#
# Usage:
#   ./add_yolo_model.sh \
#       --weights /path/to/best.pt \
#       --name "Road Defects" \
#       --slug road_defects \
#       --classes cracks,potholes,raveling,sw \
#       [--threshold 0.25] [--force]
#
# Teammates: scp your .pt to the server first, then point --weights at it.
# IMPORTANT: --classes order MUST match the model's training class order,
# otherwise predictions get the wrong labels.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
TEMPLATE_DIR="$SCRIPT_DIR/_template"
LOCKFILE="/tmp/cvat-yolo-deploy.lock"
ALPINE_TAG="gcr.io/iguazio/alpine:3.17"  # helper image nuclio needs for volume mounts

WEIGHTS=""
NAME=""
SLUG=""
CLASSES=""
THRESHOLD="0.25"
FORCE=0

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">> $*"; }

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ---- parse args ----
while [ $# -gt 0 ]; do
    case "$1" in
        --weights)   WEIGHTS="${2:-}"; shift 2;;
        --name)      NAME="${2:-}"; shift 2;;
        --slug)      SLUG="${2:-}"; shift 2;;
        --classes)   CLASSES="${2:-}"; shift 2;;
        --threshold) THRESHOLD="${2:-}"; shift 2;;
        --force)     FORCE=1; shift;;
        -h|--help)   usage 0;;
        *) die "Unknown argument: $1 (use --help)";;
    esac
done

# ---- validate ----
[ -n "$WEIGHTS" ] || die "--weights is required"
[ -n "$NAME" ]    || die "--name is required"
[ -n "$SLUG" ]    || die "--slug is required"
[ -n "$CLASSES" ] || die "--classes is required"
[ -f "$WEIGHTS" ] || die "weights file not found: $WEIGHTS"
[ -d "$TEMPLATE_DIR" ] || die "template dir missing: $TEMPLATE_DIR"

# slug must be filesystem + DNS safe (lowercase alnum and dashes/underscores)
echo "$SLUG" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' \
    || die "invalid --slug '$SLUG' (use lowercase letters, digits, '-' or '_', starting alphanumeric)"

FUNC_NAME="pth-ultralytics-${SLUG}"
FUNC_DIR="$SCRIPT_DIR/$SLUG/nuclio"

# ---- build SPEC_JSON from ordered class names ----
# Produces: [ { "id": 0, "name": "cracks", "type": "rectangle" }, ... ]
build_spec() {
    local IFS=','
    read -ra arr <<< "$CLASSES"
    local out="[" first=1 i=0 c
    for c in "${arr[@]}"; do
        c="$(echo "$c" | sed 's/^ *//;s/ *$//')"   # trim
        [ -n "$c" ] || die "empty class name in --classes"
        [ $first -eq 1 ] || out+=", "
        out+="{ \"id\": $i, \"name\": \"$c\", \"type\": \"rectangle\" }"
        first=0; i=$((i+1))
    done
    out+="]"
    [ $i -gt 0 ] || die "no classes parsed from --classes"
    echo "$out"
}
SPEC_JSON="$(build_spec)"

# ---- collision guard ----
if [ -d "$SCRIPT_DIR/$SLUG" ] && [ "$FORCE" -ne 1 ]; then
    die "slug '$SLUG' already exists at $SCRIPT_DIR/$SLUG. Pick a new slug, or pass --force to replace ONLY this model."
fi

# ---- serialize concurrent deploys (each model still gets its own port) ----
exec 9>"$LOCKFILE"
if ! flock -w 600 9; then
    die "another deploy is in progress (lock: $LOCKFILE); timed out after 600s"
fi
info "Acquired deploy lock"

# ---- pre-flight: nuctl present ----
if ! command -v nuctl >/dev/null 2>&1; then
    die "nuctl not found. Install it, e.g.:
  wget https://github.com/nuclio/nuclio/releases/download/1.13.0/nuctl-1.13.0-linux-amd64
  sudo chmod +x nuctl-1.13.0-linux-amd64
  sudo mv nuctl-1.13.0-linux-amd64 /usr/local/bin/nuctl"
fi

# ---- pre-flight: cvat project exists (idempotent) ----
if ! nuctl get project cvat --platform local >/dev/null 2>&1; then
    info "Creating nuclio project 'cvat'"
    nuctl create project cvat --platform local
else
    info "Nuclio project 'cvat' already exists"
fi

# ---- pre-flight: alpine helper image (nuclio pulls a tag that may be gone) ----
if ! docker image inspect "$ALPINE_TAG" >/dev/null 2>&1; then
    info "Helper image $ALPINE_TAG missing; retagging a local alpine"
    LOCAL_ALPINE="$(docker images --format '{{.Repository}}:{{.Tag}}' \
        | grep -E '(^|/)alpine:' | head -n1 || true)"
    if [ -z "$LOCAL_ALPINE" ]; then
        info "No local alpine found; pulling alpine:3.17"
        docker pull alpine:3.17
        LOCAL_ALPINE="alpine:3.17"
    fi
    docker tag "$LOCAL_ALPINE" "$ALPINE_TAG"
    info "Tagged $LOCAL_ALPINE -> $ALPINE_TAG"
fi

# ---- render template ----
info "Rendering function into $FUNC_DIR"
rm -rf "$SCRIPT_DIR/$SLUG"
mkdir -p "$FUNC_DIR"
cp "$TEMPLATE_DIR/main.py" "$FUNC_DIR/main.py"
cp "$WEIGHTS" "$FUNC_DIR/model.pt"

# Use python for safe placeholder substitution (NAME/SPEC may contain spaces/quotes).
NAME="$NAME" SLUG="$SLUG" SPEC_JSON="$SPEC_JSON" \
python3 - "$TEMPLATE_DIR/function.yaml.tmpl" "$FUNC_DIR/function.yaml" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    text = f.read()
for key in ("NAME", "SLUG", "SPEC_JSON"):
    text = text.replace("{{%s}}" % key, os.environ[key])
with open(dst, "w") as f:
    f.write(text)
PY

# ---- deploy (official flags: cvat network + redis) ----
info "Deploying '$FUNC_NAME' (this builds a docker image; first time pulls PyTorch, ~10-15 min)"
nuctl deploy --project-name cvat --path "$FUNC_DIR" \
    --file "$FUNC_DIR/function.yaml" --platform local \
    --env CVAT_FUNCTIONS_REDIS_HOST=cvat_redis_ondisk \
    --env CVAT_FUNCTIONS_REDIS_PORT=6666 \
    --platform-config '{"attributes": {"network": "cvat_cvat"}}'

# ---- post-deploy: normalize nuclio store files ----
# Nuclio's local store lists functions via `cat <dir>/*` split BY NEWLINE, decoding
# each line as one resource. So every *.json MUST end with exactly one '\n' (the row
# separator). A file missing it is harmless while it's the only function, but the next
# deploy merges two files into one corrupt line -> the WHOLE Models list breaks in CVAT
# ("Could not get models from the server"). Self-heal every file, new and pre-existing.
info "Normalizing nuclio store files (ensuring trailing newline / row separator)"
docker exec nuclio-local-storage-reader sh -c '
  for f in /etc/nuclio/store/functions/nuclio/*.json; do
    [ -f "$f" ] || continue
    [ "$(tail -c1 "$f" | od -An -tx1 | tr -d " ")" = "0a" ] || printf "\n" >> "$f"
  done' || info "WARNING: store normalization step failed (continuing to health check)"

# ---- post-deploy health check ----
info "Verifying function state"
STATE_LINE="$(nuctl get function "$FUNC_NAME" --platform local 2>/dev/null | grep "$FUNC_NAME" || true)"
echo "$STATE_LINE"
# Verify the LIST read too (this is what CVAT's Models tab actually does: cat all
# function files + decode each). A single-function check can pass while the list is
# broken, so this guards the exact operation CVAT relies on.
if ! nuctl get functions --platform local >/dev/null 2>&1; then
    die "deploy left the nuclio function LIST unreadable -- CVAT's Models tab would show
'Could not get models from the server'. The store likely has a function file missing its
trailing newline; re-run, or normalize: for each /etc/nuclio/store/functions/nuclio/*.json
ensure it ends with a single '\n', then 'nuctl get functions --platform local'."
fi
if echo "$STATE_LINE" | grep -q "ready"; then
    info "SUCCESS: '$NAME' is ready. Refresh the CVAT Models tab to use it."
else
    cat >&2 <<EOF

WARNING: '$FUNC_NAME' did not reach 'ready' state.
This sometimes happens when nuclio's local state lags behind the container.
Try:
  1) Confirm the container is up:  docker ps | grep $SLUG
  2) Restart nuclio to resync:     docker restart nuclio
  3) Re-check:                     nuctl get functions --platform local
If it still shows 'building' with no port, the function container is healthy but
nuclio's stored state is stale — contact the maintainer to apply the state-file
patch (we hit this once during initial setup).
EOF
    exit 1
fi
