#!/usr/bin/env bash
# Run on the NUC as root: installs the weekly SMART check and enables its timer.
# Put DISK_HEALTH_TOKEN=... (and optionally GATUS_URL, SMART_DEVICE) in
# /etc/default/homelab-smart-check (chmod 600) first. Needs smartmontools and python3.
set -euo pipefail
cd "$(dirname "$0")"
install -m 0755 homelab-smart-check.sh /usr/local/sbin/homelab-smart-check.sh
install -m 0644 homelab-smart-check.service homelab-smart-check.timer /etc/systemd/system/
install -d -m 0700 /var/lib/homelab-smart
systemctl daemon-reload
systemctl enable --now homelab-smart-check.timer
systemctl list-timers homelab-smart-check.timer --no-pager
