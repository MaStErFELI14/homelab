#!/usr/bin/env bash
# Run on the NUC as root: installs the dead-man's-switch script and enables its timer.
# Put HEALTHCHECK_PING_URL=... in /etc/default/homelab-heartbeat (chmod 600) first.
set -euo pipefail
cd "$(dirname "$0")"
install -m 0755 homelab-heartbeat.sh /usr/local/sbin/homelab-heartbeat.sh
install -m 0644 homelab-heartbeat.service homelab-heartbeat.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now homelab-heartbeat.timer
systemctl list-timers homelab-heartbeat.timer --no-pager
