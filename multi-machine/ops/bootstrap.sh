#!/bin/bash
# =============================================================================
#  MACHINE bootstrap — run ONCE on each fresh Ubuntu (24.04 LTS recommended)
#  - sets the role hostname
#  - verifies the role's static IP; optionally applies it via netplan (--set-ip)
#  - installs Docker Engine + docker compose + helpers (envsubst, ufw, ...)
#  - applies a small sysctl baseline
#  Idempotent — safe to re-run.
#
#  Usage (root):
#     sudo bash ops/bootstrap.sh mon|storage|auth [--set-ip]
#
#  Roles (IPs are provider-assigned STATIC; override per role via env or via
#  MON_IP / STORAGE_IP / AUTH_IP — provision-all.sh passes them):
#     mon     -> nama-mon-stack   ${MON_IP:-172.29.50.2}
#     storage -> namastorage      ${STORAGE_IP:-172.29.50.3}
#     auth    -> nama-auth-vm     ${AUTH_IP:-172.29.50.4}
#
#  --set-ip: writes a static netplan and applies it. The NIC must already be
#            reachable on the app VLAN (same CIDR as NET_CIDR), and your SSH
#            session will DROP if the IP changes. Prefer a DHCP reservation.
# =============================================================================
set -euo pipefail

ROLE="${1:-}"
SET_IP=false
[ "${2:-}" = "--set-ip" ] && SET_IP=true

case "$ROLE" in
  mon)     HOSTNAME_NEW="nama-mon-stack"; WANT_IP="${MON_IP:-172.29.50.2}" ;;
  storage) HOSTNAME_NEW="namastorage";    WANT_IP="${STORAGE_IP:-172.29.50.3}" ;;
  auth)    HOSTNAME_NEW="nama-auth-vm";   WANT_IP="${AUTH_IP:-172.29.50.4}" ;;
  *) echo "Usage: $0 mon|storage|auth [--set-ip]"; exit 2 ;;
esac

NET_CIDR="${NET_CIDR:-172.29.50.0/24}"   # app-VLAN CIDR (override for provider subnet)
GATEWAY="${GATEWAY:-172.29.50.1}"     # app-VLAN gateway (usually the F5 self-IP)
DOCKER_VERSION="${DOCKER_VERSION:-}"  # e.g. 28.3.3 — empty = latest

[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root (sudo)"; exit 1; }

echo "=== role=$ROLE -> $HOSTNAME_NEW @ $WANT_IP ==="

# ---- 0. release sanity ----
# shellcheck disable=SC1091
. /etc/os-release
echo "OS: $PRETTY_NAME"
case "$VERSION_ID" in
  24.04|26.04) : ;;
  25.04|25.10) echo "WARNING: non-LTS (EOL within ~9 months) — use 24.04 LTS or 26.04 LTS." ;;
  *) echo "WARNING: untested release $VERSION_ID — 24.04 LTS recommended." ;;
esac

# ---- 1. hostname ----
hostnamectl set-hostname "$HOSTNAME_NEW" 2>/dev/null || true
grep -q "$HOSTNAME_NEW" /etc/hosts \
  || echo "127.0.1.1 $HOSTNAME_NEW" >> /etc/hosts

# ---- 2. IP check / optional static apply ----
CURRENT_IP="$(hostname -I | awk '{print $1}')"
if [ "$CURRENT_IP" != "$WANT_IP" ]; then
  if $SET_IP; then
    echo "Applying static IP $WANT_IP/$NET_CIDR via netplan (SSH may drop)..."
    IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"
    [ -n "$IFACE" ] || { echo "FATAL: no default-route interface found"; exit 1; }
    rm -f /etc/netplan/99-nama-static.yaml
    mkdir -p /etc/netplan
    cat > /etc/netplan/99-nama-static.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses: [${WANT_IP}/${NET_CIDR##*/}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
        search: [otech.om]
EOF
    chmod 600 /etc/netplan/99-nama-static.yaml
    netplan generate && netplan apply || true
    sleep 3
    echo "Now at $(hostname -I | awk '{print $1}') (expected $WANT_IP)"
  else
    echo "FATAL: machine is $CURRENT_IP but role $ROLE needs $WANT_IP." >&2
    echo "       Fix via DHCP reservation / cloud-init, or re-run with --set-ip." >&2
    exit 1
  fi
else
  echo "IP OK: $WANT_IP"
fi

# ---- 3. base packages ----
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg gettext-base ufw iptables openssl jq rsync

# ---- 4. Docker Engine + compose (from the official apt repo) ----
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  if [ -n "$DOCKER_VERSION" ]; then
    apt-get install -y "docker-ce=${DOCKER_VERSION}*" "docker-ce-cli=${DOCKER_VERSION}*" \
      containerd.io docker-buildx-plugin docker-compose-plugin
  else
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
fi
systemctl enable --now docker
echo "Docker : $(docker --version)"
echo "Compose: $(docker compose version)"
if [ -z "$DOCKER_VERSION" ]; then
  echo "NOTE: Docker engine not pinned — record this version and set DOCKER_VERSION on refresh."
fi

# allow the admin user to use docker without sudo (convenience, optional)
ADMIN_USER="${SUDO_USER:-ubuntu}"
id "$ADMIN_USER" >/dev/null 2>&1 && usermod -aG docker "$ADMIN_USER" || true

# ---- 5. sysctl baseline ----
cat > /etc/sysctl.d/99-nama.conf <<'EOF'
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv4.tcp_syncookies=1
EOF
sysctl --system >/dev/null

mkdir -p /opt/nama
echo "bootstrap OK: role=$ROLE host=$(hostname) ip=$(hostname -I | awk '{print $1}')"
echo "next:  sudo bash ops/ufw-mX.sh   then   /opt/nama/<role>/   deploy"