#!/usr/bin/env bash
# Run on the node as root: installs the key-only SSH drop-in (idempotent).
# Keep your current SSH session open, test with a NEW connection, then cancel the rollback.
# Safety: arms a 5 minute rollback timer that removes the drop-in and reloads sshd.
set -euo pipefail
cd "$(dirname "$0")"

DEST=/etc/ssh/sshd_config.d/10-homelab-hardening.conf

if ! grep -qs '^ssh-' /root/.ssh/authorized_keys; then
  echo "no key in /root/.ssh/authorized_keys; refusing to disable password auth" >&2
  exit 1
fi

if cmp -s 10-homelab-hardening.conf "$DEST" 2>/dev/null; then
  echo "already installed"; sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '
  exit 0
fi

systemctl stop homelab-ssh-rollback.timer 2>/dev/null || true
systemd-run --on-active=5min --unit=homelab-ssh-rollback \
  /bin/sh -c "rm -f $DEST; systemctl reload ssh"

install -m 0644 10-homelab-hardening.conf "$DEST"
if ! sshd -t; then
  rm -f "$DEST"; systemctl stop homelab-ssh-rollback.timer
  echo "sshd -t failed; drop-in removed" >&2
  exit 1
fi
systemctl reload ssh
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '
echo
echo "Verify with a new connection (key works, password refused), then cancel the rollback:"
echo "  systemctl stop homelab-ssh-rollback.timer"
