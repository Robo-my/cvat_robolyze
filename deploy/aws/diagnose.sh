#!/usr/bin/env bash
# Snapshot of where a slow CVAT host is spending its time.
# Run it on the host while users are opening jobs, a few times in a row.
#
# Usage: deploy/aws/diagnose.sh [seconds-to-watch-queues]   (default 30)

set -uo pipefail

WATCH_SECONDS=${1:-30}
REDIS_CONTAINER=${REDIS_CONTAINER:-cvat_redis_inmem}

section() { printf '\n== %s\n' "$1"; }

section "Host"
uptime
free -h
nproc | sed 's/^/vCPUs: /'

section "Containers (CPU / memory)"
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.BlockIO}}' | sort -k1,1

redis() { docker exec "$REDIS_CONTAINER" redis-cli "$@"; }

section "RQ queue lengths (jobs waiting), every 5 s for ${WATCH_SECONDS}s"
echo "A chunks queue that stays above 0 means users are waiting for chunk workers."
queues=$(redis SMEMBERS rq:queues 2>/dev/null | sort)
if [[ -z $queues ]]; then
    echo "   could not read queues from $REDIS_CONTAINER"
else
    end=$((SECONDS + WATCH_SECONDS))
    while (( SECONDS < end )); do
        line="$(date +%T)"
        for q in $queues; do
            line+="  ${q#rq:queue:}=$(redis LLEN "$q")"
        done
        echo "$line"
        sleep 5
    done
fi

section "Disk"
df -h / /var/lib/docker 2>/dev/null | uniq
if command -v iostat >/dev/null; then
    echo "Watch %util (near 100 = disk-bound) and r_await/w_await (ms):"
    iostat -dx 5 2 | awk 'BEGIN{n=0} /^Device/{n++} n==2'
else
    echo "iostat not installed (sudo apt install sysstat) - skipping"
fi

section "Tailscale"
if command -v tailscale >/dev/null; then
    echo "Peers marked 'relay' go through a DERP server instead of a direct connection,"
    echo "which limits throughput. Allow inbound UDP 41641 in the Security Group to fix that."
    tailscale status | grep -v '^#' || true
else
    echo "tailscale CLI not found"
fi
