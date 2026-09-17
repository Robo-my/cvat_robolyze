#!/bin/bash
# Install the CVAT EC2 automation (auto-start, health check, 21:00 MYT auto-stop, NAS backups).
# Run on the EC2 host from the repo checkout:  sudo deploy/ec2/install.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -d -m 755 /opt/cvat
install -m 750 "$HERE"/bin/*.sh /opt/cvat/
install -m 644 "$HERE"/systemd/* /etc/systemd/system/
if [ ! -f /etc/cvat-backup.conf ]; then
    install -m 600 "$HERE"/cvat-backup.conf.example /etc/cvat-backup.conf
    echo "Created /etc/cvat-backup.conf from the example: set the NAS credentials in it"
fi
timedatectl set-timezone Asia/Kuala_Lumpur
systemctl daemon-reload
systemctl enable docker tailscaled cvat.service cvat-healthcheck.timer cvat-autostop.timer cvat-backup.timer
systemctl start cvat-autostop.timer cvat-backup.timer
systemctl list-timers 'cvat-*' --no-pager
