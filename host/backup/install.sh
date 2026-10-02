#!/usr/bin/env bash
# Run on the NUC as root: installs the backup script and enables the nightly timer.
set -euo pipefail
cd "$(dirname "$0")"
install -m 0755 k3s-backup.sh /usr/local/sbin/k3s-backup.sh
install -m 0644 k3s-backup.service k3s-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now k3s-backup.timer
systemctl list-timers k3s-backup.timer --no-pager
