#!/bin/bash
# Clean stop of CVAT (flushes Postgres) and the model containers.
set -uo pipefail
cd /home/ubuntu/cvat_robolyze
C="docker compose -f docker-compose.yml -f components/serverless/docker-compose.serverless.yml"
$C stop -t 60
ids=$(docker ps -q --filter "name=^nuclio-nuclio-")
[ -n "$ids" ] && docker stop -t 30 $ids >/dev/null
echo "cvat-stop: done"
