#!/usr/bin/env bash
# One-time setup so the CVAT host survives a nightly stop/start without manual steps.
# Safe to run more than once.
#
# Usage: sudo deploy/aws/host-setup.sh [--restart-docker]
#
# --restart-docker  apply a changed /etc/docker/daemon.json right away
#                   (this restarts every container, so CVAT is down for ~1-2 min)

set -euo pipefail

SHUTDOWN_TIMEOUT=60
DAEMON_JSON=/etc/docker/daemon.json
RESTART_DOCKER=false

for arg in "$@"; do
    case "$arg" in
        --restart-docker) RESTART_DOCKER=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
fi

echo "== Enabling docker and tailscaled at boot"
for unit in docker tailscaled; do
    if ! systemctl list-unit-files "$unit.service" >/dev/null 2>&1; then
        echo "   WARNING: $unit.service not found"
        continue
    fi
    systemctl enable "$unit" >/dev/null 2>&1
    echo "   $unit: $(systemctl is-enabled "$unit")"
done

echo "== Docker shutdown timeout (lets Postgres stop cleanly on instance stop)"
changed=$(python3 - "$DAEMON_JSON" "$SHUTDOWN_TIMEOUT" <<'EOF'
import json, os, sys
path, timeout = sys.argv[1], int(sys.argv[2])
config = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        config = json.load(f)
if config.get("shutdown-timeout") == timeout:
    print("no")
else:
    config["shutdown-timeout"] = timeout
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    print("yes")
EOF
)

if [[ $changed == yes ]]; then
    echo "   wrote shutdown-timeout=$SHUTDOWN_TIMEOUT to $DAEMON_JSON"
    if $RESTART_DOCKER; then
        systemctl restart docker
        echo "   docker restarted"
    else
        echo "   takes effect on the next docker restart or reboot (or rerun with --restart-docker)"
    fi
else
    echo "   already set"
fi

echo "== Containers without an automatic restart policy (will NOT come back after boot)"
missing=0
while read -r name policy; do
    if [[ $policy != always && $policy != unless-stopped ]]; then
        echo "   $name (restart policy: ${policy:-none})"
        missing=1
    fi
done < <(docker ps -a --format '{{.Names}}' | xargs -r docker inspect --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' | sed 's|^/||')
[[ $missing -eq 0 ]] && echo "   none"

echo "== Tailscale"
if command -v tailscale >/dev/null; then
    echo "   IPv4: $(tailscale ip -4 2>/dev/null || echo unknown)"
    echo "   Remember to disable key expiry for this machine in the Tailscale admin console."
else
    echo "   WARNING: tailscale CLI not found"
fi
