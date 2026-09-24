#!/bin/bash
# =============================================================================
#  UFW firewall for MACHINE 1 — nama-mon-stack (172.29.50.2)
#  Default-deny inbound; explicit allow-list. Run as root.
#
#  Adjust F5_IP / MGMT_CIDR for your environment before first run.
#  See ../PRODUCTION-SECURITY-DESIGN.md §9.1.
#
#  EXAMPLE values — change to match your environment (provider-assigned IPs):
#    F5_IP=172.29.50.1        # F5 self-IP on the app VLAN
#    MGMT_CIDR=10.0.10.0/24   # admin/bastion SSH subnet (jump host)
#    MON_IP=172.29.50.2       # this VM (also set in .env)
#    STORAGE_IP=172.29.50.3   # VM2 (also set in .env)
#
#  Run with your values (or edit the defaults below):
#    sudo MGMT_CIDR=10.0.10.0/24 F5_IP=172.29.50.1 MON_IP=172.29.50.2 STORAGE_IP=172.29.50.3 ./ufw-m1.sh
# =============================================================================
set -euo pipefail

F5_IP="${F5_IP:-172.29.50.1}"        # F5 floating management/VIP source
MGMT_CIDR="${MGMT_CIDR:-10.0.10.0/24}"  # admin SSH network
ADMIN_CIDR="${ADMIN_CIDR:-}"          # extra SSH source (e.g. jump host /32)
MON_IP="${MON_IP:-172.29.50.2}"     # THIS VM (nama-mon-stack)
STORAGE_IP="${STORAGE_IP:-172.29.50.3}"  # VM2 (vmagent) — source for 8427/9100

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# management SSH
ufw allow from "$MGMT_CIDR" to any port 22 proto tcp
[ -n "$ADMIN_CIDR" ] && ufw allow from "$ADMIN_CIDR" to any port 22 proto tcp
# PRE-F5 TEMP: admin LAN -> Grafana UI directly (remove once F5 VIP is live)
ufw allow from "$MGMT_CIDR" to "$MON_IP" port 3000 proto tcp
[ -n "$ADMIN_CIDR" ] && ufw allow from "$ADMIN_CIDR" to "$MON_IP" port 3000 proto tcp
# F5 -> Grafana
ufw allow from "$F5_IP" to "$MON_IP" port 3000 proto tcp
# VM2 -> Grafana HTTPS (interim nip.io blackbox probe; revert to F5-only once
# blackbox probes the F5 VIP instead of the VM IP)
ufw allow from "$STORAGE_IP" to "$MON_IP" port 3000 proto tcp
# VM2 -> vmauth (TLS) and node-exporter
ufw allow from "$STORAGE_IP" to "$MON_IP" port 8427 proto tcp
ufw allow from "$STORAGE_IP" to "$MON_IP" port 9100 proto tcp
ufw --force enable
ufw status numbered

# ---- Docker forwarding: Docker-published ports bypass UFW INPUT; ----
# mirror the same policy in the DOCKER-USER chain (docker ~2004 forward).
# NOTE: docker DNATs published ports to container IPs in PREROUTING, so we
# match source + dport (NOT host dest IP). Container egress is allowed via
# the docker bridge subnet (mirror of 'allow outgoing').
BR_SUBNETS=$(ip -o -4 addr show | awk '$2 ~ /^(br-[0-9a-f]+|docker0)$/ {print $4}')
iptables -F DOCKER-USER 2>/dev/null
[ -n "$BR_SUBNETS" ] && for s in $BR_SUBNETS; do iptables -A DOCKER-USER -s "$s" -j ACCEPT; done
iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 3000 -s "$MGMT_CIDR" -j ACCEPT   # PRE-F5 TEMP
[ -n "$ADMIN_CIDR" ] && iptables -A DOCKER-USER -p tcp --dport 3000 -s "$ADMIN_CIDR" -j ACCEPT  # PRE-F5 TEMP
iptables -A DOCKER-USER -p tcp --dport 3000 -s "$F5_IP" -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 3000 -s "$STORAGE_IP" -j ACCEPT   # interim nip.io blackbox probe
iptables -A DOCKER-USER -p tcp --dport 8427 -s "$STORAGE_IP" -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 9100 -s "$STORAGE_IP" -j ACCEPT
iptables -A DOCKER-USER -j DROP   # default deny for the rest of forwarded traffic

echo
echo "VM1 firewall applied. No 8428 published by compose anyway — ss -lntup to confirm."