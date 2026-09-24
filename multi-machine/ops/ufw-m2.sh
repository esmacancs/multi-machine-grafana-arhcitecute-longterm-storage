#!/bin/bash
# =============================================================================
#  UFW firewall for MACHINE 2 — namastorage (172.29.50.3)
#  Default-deny inbound; only local/topology-implied traffic opens.
#  Run as root.  Adjust MGMT_CIDR / MON_CIDR before first run.
#  See ../PRODUCTION-SECURITY-DESIGN.md §9.2.
#
#  EXAMPLE values — change to match your environment (provider-assigned IPs):
#    MGMT_CIDR=10.0.10.0/24   # admin/bastion SSH subnet (jump host)
#    MON_CIDR=172.29.50.0/24  # monitoring/infra VLAN that scrapes the exporters
#    STORAGE_IP=172.29.50.3   # this VM (also set in .env)
#
#  Run with your values (or edit the defaults below):
#    sudo MGMT_CIDR=10.0.10.0/24 MON_CIDR=172.29.50.0/24 STORAGE_IP=172.29.50.3 ./ufw-m2.sh
# =============================================================================
set -euo pipefail

MGMT_CIDR="${MGMT_CIDR:-10.0.10.0/24}"  # admin SSH + LAN monitoring
ADMIN_CIDR="${ADMIN_CIDR:-}"            # extra SSH source (e.g. jump host /24)
STORAGE_IP="${STORAGE_IP:-172.29.50.3}" # THIS VM (namastorage)
# Instrumented LAN the exporters/targets live on (monitoring + infra VLAN):
MON_CIDR="${MON_CIDR:-172.29.50.0/24}"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# management SSH
ufw allow from "$MGMT_CIDR" to any port 22 proto tcp
[ -n "$ADMIN_CIDR" ] && ufw allow from "$ADMIN_CIDR" to any port 22 proto tcp

# LAN-bound exporters (node 9100, blackbox 9115, fortigate 9710, oci ports)
ufw allow from "$MON_CIDR" to "$STORAGE_IP" port 9100 proto tcp
ufw allow from "$MON_CIDR" to "$STORAGE_IP" port 9115 proto tcp
ufw allow from "$MON_CIDR" to "$STORAGE_IP" port 9710 proto tcp
# ... extend for OCI appliance exporters when their ports are known

# vmagent runs HERE and scrapes these same published ports via the host IP —
# that hairpin lands on the docker-proxy (INPUT) path, so the docker bridge
# subnets must be allowed too (destination is already port/from scoped).
BR_SUBNETS=$(ip -o -4 addr show | awk '$2 ~ /^(br-[0-9a-f]+|docker0)$/ {print $4}')
for s in $BR_SUBNETS; do
  ufw allow from "$s" to "$STORAGE_IP" port 9100 proto tcp
  ufw allow from "$s" to "$STORAGE_IP" port 9115 proto tcp
  ufw allow from "$s" to "$STORAGE_IP" port 9710 proto tcp
done

# vmagent UI / pushgateway are loopback-only (bound to 127.0.0.1) -> no rule.

ufw --force enable
ufw status numbered

# ---- DOCKER-USER mirror: only allow inbound to LAN-published exporter ports ----
# docker DNATs published ports to container IPs, so match source+dport (not dest IP).
BR_SUBNETS=$(ip -o -4 addr show | awk '$2 ~ /^(br-[0-9a-f]+|docker0)$/ {print $4}')
iptables -F DOCKER-USER 2>/dev/null
[ -n "$BR_SUBNETS" ] && for s in $BR_SUBNETS; do iptables -A DOCKER-USER -s "$s" -j ACCEPT; done
iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 9100 -s "$MON_CIDR" -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 9115 -s "$MON_CIDR" -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 9710 -s "$MON_CIDR" -j ACCEPT
iptables -A DOCKER-USER -j DROP

echo
echo "VM2 firewall applied. Exporters on the loopback (8429/9091) are never reachable from the LAN."