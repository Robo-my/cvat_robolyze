#!/bin/bash
# Bring up CVAT (always with the serverless overlay) and the nuclio model containers.
set -euo pipefail
cd /home/ubuntu/cvat_robolyze
C="docker compose -f docker-compose.yml -f components/serverless/docker-compose.serverless.yml"
$C up -d
ids=$(docker ps -aq --filter "name=^nuclio-nuclio-")
[ -n "$ids" ] && docker start $ids >/dev/null
echo "cvat-start: stack up, $(echo $ids | wc -w) model containers started"
