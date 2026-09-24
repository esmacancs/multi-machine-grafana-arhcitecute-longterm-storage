#!/bin/bash
# =============================================================================
#  UFW firewall for MACHINE 3 — nama-auth-vm (172.29.50.4)
#  Default-deny inbound. Keycloak app HTTP (8080, redirects to HTTPS) + interim
#  direct HTTPS (8443, now the REAL app port during the no-F5/nip.io phase) only
#  from F5 + VM1 (Grafana OIDC discovery/JWKS) + VM2 (blackbox probe);
#  management+metrics (9000) and node-exporter (9100) only from VM2; SSH from
#  management. Run as root.  Adjust F5_IP / MGMT_CIDR before first run.
#  See ../PRODUCTION-SECURITY-DESIGN.md §9.3.
#
#  EXAMPLE values — change to match your environment (provider-assigned IPs):
#    F5_IP=172.29.50.1        # F5 self-IP on the app VLAN
#    MGMT_CIDR=10.0.10.0/24   # admin/bastion SSH subnet (jump host)
#    MON_CIDR=172.29.50.0/24  # monitoring VLAN — only if blackbox probes
#                              # the Keycloak VIP directly over LAN
#    AUTH_IP=172.29.50.4      # this VM (also set in .env)
#    MON_IP=172.29.50.2       # VM1 (also set in .env)
#    STORAGE_IP=172.29.50.3   # VM2 (also set in .env)
#
#  Run with your values (or edit the defaults below):
#    sudo MGMT_CIDR=10.0.10.0/24 F5_IP=172.29.50.1 \
#         AUTH_IP=172.29.50.4 MON_IP=172.29.50.2 STORAGE_IP=172.29.50.3 ./ufw-m3.sh
# =============================================================================
set -euo pipefail

F5_IP="${F5_IP:-172.29.50.1}"
MGMT_CIDR="${MGMT_CIDR:-10.0.10.0/24}"
ADMIN_CIDR="${ADMIN_CIDR:-}"            # extra SSH/UI source (jump host /24)
MON_CIDR="${MON_CIDR:-172.29.50.0/24}"   # optional: blackbox direct probes
AUTH_IP="${AUTH_IP:-172.29.50.4}"   # THIS VM (nama-auth-vm)
MON_IP="${MON_IP:-172.29.50.2}"     # VM1 Grafana backend -> Keycloak OIDC discovery / JWKS
STORAGE_IP="${STORAGE_IP:-172.29.50.3}" # VM2 (vmagent) scrapes KC metrics + node

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# management SSH
ufw allow from "$MGMT_CIDR" to any port 22 proto tcp
[ -n "$ADMIN_CIDR" ] && ufw allow from "$ADMIN_CIDR" to any port 22 proto tcp
# PRE-F5 TEMP: admin LAN -> Keycloak directly (remove once F5 VIP is live)
ufw allow from "$MGMT_CIDR" to "$AUTH_IP" port 8080 proto tcp
[ -n "$ADMIN_CIDR" ] && ufw allow from "$ADMIN_CIDR" to "$AUTH_IP" port 8080 proto tcp
ufw allow from "$MGMT_CIDR" to "$AUTH_IP" port 8443 proto tcp
[ -n "$ADMIN_CIDR" ] && ufw allow from "$ADMIN_CIDR" to "$AUTH_IP" port 8443 proto tcp
# F5 -> Keycloak app (browser-visible, TLS-terminated on F5)
ufw allow from "$F5_IP" to "$AUTH_IP" port 8080 proto tcp
ufw allow from "$F5_IP" to "$AUTH_IP" port 8443 proto tcp
# VM1 (Grafana) -> Keycloak app: OIDC discovery + token/JWKS validation
ufw allow from "$MON_IP" to "$AUTH_IP" port 8080 proto tcp
ufw allow from "$MON_IP" to "$AUTH_IP" port 8443 proto tcp
# VM2 -> interim nip.io HTTPS blackbox probe of Keycloak (revert to F5-only
# once blackbox probes the F5 VIP), KC26 management + node-exporter
ufw allow from "$STORAGE_IP" to "$AUTH_IP" port 8443 proto tcp
ufw allow from "$STORAGE_IP" to "$AUTH_IP" port 9000 proto tcp
ufw allow from "$STORAGE_IP" to "$AUTH_IP" port 9100 proto tcp
# Optional: blackbox exporter probing Keycloak directly (the public KC VIP
# via F5 does NOT need this — it is added as-is for direct-LAN probes):
# ufw allow from "$MON_CIDR" to "$AUTH_IP" port 8080 proto tcp
# ufw allow from "$MON_CIDR" to "$AUTH_IP" port 8443 proto tcp
ufw --force enable
ufw status numbered

# ---- DOCKER-USER mirror ----
# docker DNATs published ports to container IPs, so match source+dport (not dest IP).
BR_SUBNETS=$(ip -o -4 addr show | awk '$2 ~ /^(br-[0-9a-f]+|docker0)$/ {print $4}')
iptables -F DOCKER-USER 2>/dev/null
[ -n "$BR_SUBNETS" ] && for s in $BR_SUBNETS; do iptables -A DOCKER-USER -s "$s" -j ACCEPT; done
iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 8080 -s "$MGMT_CIDR" -j ACCEPT   # PRE-F5 TEMP
[ -n "$ADMIN_CIDR" ] && iptables -A DOCKER-USER -p tcp --dport 8080 -s "$ADMIN_CIDR" -j ACCEPT  # PRE-F5 TEMP
iptables -A DOCKER-USER -p tcp --dport 8443 -s "$MGMT_CIDR" -j ACCEPT   # PRE-F5 TEMP
[ -n "$ADMIN_CIDR" ] && iptables -A DOCKER-USER -p tcp --dport 8443 -s "$ADMIN_CIDR" -j ACCEPT  # PRE-F5 TEMP
iptables -A DOCKER-USER -p tcp --dport 8080 -s "$F5_IP" -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 8080 -s "$MON_IP" -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 8443 -s "$F5_IP" -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 8443 -s "$MON_IP" -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 8443 -s "$STORAGE_IP" -j ACCEPT   # interim nip.io blackbox probe
iptables -A DOCKER-USER -p tcp --dport 9000 -s "$STORAGE_IP" -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 9100 -s "$STORAGE_IP" -j ACCEPT
iptables -A DOCKER-USER -j DROP

echo
echo "VM3 firewall applied. Postgres publishes no host port (kcnet only). 8080 + 8443 only from F5/VMs."