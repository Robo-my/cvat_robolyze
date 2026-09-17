#!/bin/bash
# 21:00 MYT hard stop: wait for a running backup (max 25 min), stop CVAT cleanly, power off (instance -> stopped).
set -uo pipefail
echo "autostop: waiting for backup lock"
exec 9>/run/cvat-backup.lock
flock -w 1500 9 || echo "autostop: backup still running after 25 min, stopping anyway"
systemctl stop cvat.service
echo "autostop: powering off"
systemctl poweroff
