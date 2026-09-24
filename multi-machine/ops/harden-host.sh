#!/bin/bash
# =============================================================================
#  Common Linux host hardening — run on ALL three VMs (root).
#  Idempotent.  See ../PRODUCTION-SECURITY-DESIGN.md §9.4.
#
#  * unattended-upgrades (security + optional reboot)
#  * SSH hardening (no root, key-only)
#  * fail2ban sshd jail
#  * journald retention (2G / 30d)
#  * docker log rotation + daemon config
#  * chrony (NTP)
#  * base packages + audit basics
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> packages"
apt-get update -y
apt-get install -y unattended-upgrades ufw fail2ban chrony curl jq auditd

echo "==> unattended-upgrades"
cat >/etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };
Unattended-Upgrade::Automatic-Reboot "false";
EOF
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
EOF
systemctl enable unattended-upgrades

echo "==> SSH hardening"
if [ -d /etc/ssh/sshd_config.d ]; then
  cat >/etc/ssh/sshd_config.d/99-nama-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
else
  sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin no/;
           s/^#?PasswordAuthentication.*/PasswordAuthentication no/;
           s/^#?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
fi
systemctl reload sshd || systemctl reload ssh

echo "==> fail2ban"
cat >/etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 600
findtime = 600
EOF
systemctl enable fail2ban && systemctl restart fail2ban

echo "==> journald retention"
mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/retention.conf <<'EOF'
[Journal]
SystemMaxUse=2G
MaxRetentionSec=30day
Compress=yes
EOF
systemctl restart systemd-journald

echo "==> docker daemon (log rotation + no anonymous pull logs)"
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  "live-restore": true
}
EOF
systemctl restart docker

echo "==> chrony (NTP)"
systemctl enable chrony && systemctl restart chrony

echo "==> auditd rules (best-effort)"
cat >/etc/audit/rules.d/nama.rules <<'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group  -p wa -k identity
-w /etc/docker/daemon.json -p wa -k docker
-w /usr/local/bin -p x
EOF
auditctl -R /etc/audit/rules.d/nama.rules 2>/dev/null || true

echo
echo "Hardening applied. Reboot once and verify: ss -lntup | grep -E ':22|:8080|:3000'"