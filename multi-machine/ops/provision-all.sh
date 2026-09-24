#!/bin/bash
# =============================================================================
#  UNATTENDED provisioner — 3 fresh Ubuntu machines -> full NAMA stack.
#
#  Run ONCE from your admin workstation / jump host. Needs local: bash, ssh,
#  ssh key access to each machine, openssl (for gen-secrets/gen-ca), tar.
#
#  IMPUT: the three POSITIONAL args are the provider-assigned STATIC IPs.
#  The provisioner writes them into each machine's .env (MON_IP / STORAGE_IP /
#  AUTH_IP) and passes them to bootstrap + UFW, so compose binds, scrape.yml,
#  the CA SAN and the firewalls all line up. Do NOT edit those keys by hand.
#
#  Per machine it: waits for SSH, pushes the machine tree + ops/ to
#  /opt/nama/<role>/, runs bootstrap.sh, generates/distributes secrets+CA once,
#  deploys the stack, applies the UFW/DOCKER-USER firewall, then health-checks.
#
#  Usage:
#    ops/provision-all.sh <MON_IP> <STORAGE_IP> <AUTH_IP> \
#        [--user ubuntu] [--set-ip] [--skip-firewall] \
#        [--mgmt-cidr 10.0.10.0/24] [--admin-cidr 10.0.160.236/32] \
#        [--f5-ip 172.29.50.1] [--gateway 172.29.50.1] [--mon-cidr 172.29.50.0/24]
#
#  Notes:
#    * Requires passwordless sudo for USER on each box (cloud images: default).
#    * If the machines are NOT yet on the app VLAN/CIDR, add --set-ip (their NIC
#      must be on that subnet or the SSH session dies mid-run).
#    * MGMT_CIDR must contain THIS workstation's IP, or ufw will lock you out.
#      (The provisioner re-probes SSH after the firewall and warns you.)
#    * Edit each machine's .env before running to override image tags/F5 values.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

IP_MON="${1:?usage: provision-all.sh IP_MON IP_STORAGE IP_AUTH [flags]}"
IP_STORAGE="${2:?}"
IP_AUTH="${3:?}"
shift 3

USER="ubuntu"; SET_IP=false; SKIP_FW=false; MGMT_CIDR="10.0.10.0/24"; F5_IP="172.29.50.1"; MON_CIDR="172.29.50.0/24"; GATEWAY=""; ADMIN_CIDR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER="$2"; shift 2 ;;
    --set-ip) SET_IP=true; shift ;;
    --skip-firewall) SKIP_FW=true; shift ;;
    --mgmt-cidr) MGMT_CIDR="$2"; shift 2 ;;
    --admin-cidr) ADMIN_CIDR="$2"; shift 2 ;;
    --f5-ip) F5_IP="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    --mon-cidr) MON_CIDR="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done
[ -n "$GATEWAY" ] || GATEWAY="$F5_IP"

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5"
SET_IP_FLAG=""; $SET_IP && SET_IP_FLAG="--set-ip"

say() { echo; echo "########## $* ##########"; }

declare -A ROLE_DIR=( [mon]=machine1-nama-mon-stack [storage]=machine2-namastorage [auth]=machine3-nama-auth-vm )
declare -A ROLE_UFW=( [mon]=ufw-m1.sh [storage]=ufw-m2.sh [auth]=ufw-m3.sh )
declare -A ROLE_IPVAR=( [mon]=MON_IP [storage]=STORAGE_IP [auth]=AUTH_IP )

# ---- 0. local prereqs ----
command -v ssh >/dev/null || { echo "FATAL: ssh not found"; exit 1; }
command -v tar >/dev/null || { echo "FATAL: tar not found"; exit 1; }
command -v openssl >/dev/null || { echo "FATAL: openssl not found (needed for gen-secrets/gen-ca)"; exit 1; }
command -v sed >/dev/null || { echo "FATAL: sed not found"; exit 1; }

# ---- 1. standalone configs: .env from examples, then stamp the static IPs ----
set_kv() { # file key value
  local f="$1" k="$2" v="$3"
  if grep -q "^${k}=" "$f"; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$f"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}
for d in "${ROLE_DIR[@]}"; do
  [ -f "$d/.env" ] || { cp "$d/.env.example" "$d/.env"; echo "note: created $d/.env from example"; }
done
set_kv "${ROLE_DIR[mon]}/.env"     MON_IP     "$IP_MON"
set_kv "${ROLE_DIR[storage]}/.env" STORAGE_IP "$IP_STORAGE"
set_kv "${ROLE_DIR[storage]}/.env" VMAUTH_IP  "$IP_MON"
set_kv "${ROLE_DIR[storage]}/.env" MON_IP     "$IP_MON"
set_kv "${ROLE_DIR[storage]}/.env" AUTH_IP    "$IP_AUTH"
set_kv "${ROLE_DIR[auth]}/.env"    AUTH_IP    "$IP_AUTH"
# interim nip.io public hostnames — stamped so they always match the IPs.
# Editable in each .env; swap to F5 VIP names when the VIP is live.
set_kv "${ROLE_DIR[mon]}/.env"     GF_SERVER_ROOT_URL "https://grafana.${IP_MON}.nip.io:3000"
set_kv "${ROLE_DIR[mon]}/.env"     KC_PUBLIC_URL      "https://auth.${IP_AUTH}.nip.io:8443"
set_kv "${ROLE_DIR[auth]}/.env"    KC_HOSTNAME        "auth.${IP_AUTH}.nip.io"
set_kv "${ROLE_DIR[storage]}/.env" GF_PUBLIC_URL      "https://grafana.${IP_MON}.nip.io:3000"
set_kv "${ROLE_DIR[storage]}/.env" KC_PUBLIC_URL      "https://auth.${IP_AUTH}.nip.io:8443"
echo "IPs: mon=$IP_MON storage=$IP_STORAGE auth=$IP_AUTH (written to .env files)"

# ---- 2. secrets + internal CA + nip.io leaf certs (generated ONCE, here) ----
say "generating secrets + internal CA"
bash ops/gen-secrets.sh
if [ ! -f "${ROLE_DIR[mon]}/secrets/vmauth_ca.pem" ]; then
  VMAUTH_IP="$IP_MON" bash ops/gen-ca.sh
fi
[ -f "${ROLE_DIR[storage]}/secrets/vmauth_ca.pem" ] \
  || cp "${ROLE_DIR[mon]}/secrets/vmauth_ca.pem" "${ROLE_DIR[storage]}/secrets/vmauth_ca.pem"
# interim nip.io TLS leaves for Grafana (M1) + Keycloak (M3), signed by the
# internal CA above. Re-run to rotate (idempotent — skips existing files).
MON_IP="$IP_MON" AUTH_IP="$IP_AUTH" bash ops/gen-vm-tls.sh

# ---- 3. helpers ----
wait_ssh() { # ip
  local ip="$1" n=0
  echo -n "waiting for SSH on $ip ..."
  until ssh $SSH_OPTS "$USER@$ip" true 2>/dev/null; do
    n=$((n+1)); [ "$n" -gt 60 ] && { echo " TIMEOUT"; return 1; }
    echo -n "."; sleep 5
  done
  echo " up"
}

push_tree() { # ip role localdir
  local ip="$1" role="$2" dir="$3"
  ssh $SSH_OPTS "$USER@$ip" "sudo mkdir -p /opt/nama/$role /opt/nama/ops"
  tar -C "$dir" -cf - . | ssh $SSH_OPTS "$USER@$ip" "sudo tar -C /opt/nama/$role -xf -"
  tar -C ops -cf - . | ssh $SSH_OPTS "$USER@$ip" "sudo tar -C /opt/nama/ops -xf -"
  # chown the deploy tree root-only, but NEVER the runtime data dirs
  # (postgres runs as uid 999, grafana as 472 on mon) — deploy.sh owns those.
  ssh $SSH_OPTS "$USER@$ip" "sudo bash -c '
    chown -R root:root /opt/nama/ops
    find /opt/nama/$role -name secrets -prune -o -type d \( -name postgres -o -name onetech-data \) -prune -o -exec chown root:root {} +
    find /opt/nama/$role -name secrets -prune -o -type d \( -name postgres -o -name onetech-data \) -prune -o -type d -exec chmod 750 {} +
  '"
}

provision_one() { # ip role
  local ip="$1" role="$2"  ipvar="${ROLE_IPVAR[$role]}"
  say "$role <- $ip"
  wait_ssh "$ip"
  push_tree "$ip" "$role" "${ROLE_DIR[$role]}"
  if $SET_IP; then
    # --set-ip: netplan changes the IP and the SSH session dies; run detached
    # (setsid survives SIGHUP) and reconnect on the same IP once it settles.
    echo "running bootstrap detached (--set-ip: session drop expected)..."
    ssh $SSH_OPTS "$USER@$ip" "sudo $ipvar=$ip GATEWAY=$GATEWAY NET_CIDR=$MON_CIDR setsid bash -c 'bash /opt/nama/ops/bootstrap.sh $role $SET_IP_FLAG >/var/log/nama-bootstrap.log 2>&1' </dev/null &"
    wait_ssh "$ip" || return 1
    echo "reconnected to $ip. bootstrap tail:"
    ssh $SSH_OPTS "$USER@$ip" "sudo tail -n 5 /var/log/nama-bootstrap.log"
  else
    ssh $SSH_OPTS "$USER@$ip" "sudo $ipvar=$ip GATEWAY=$GATEWAY bash /opt/nama/ops/bootstrap.sh $role"
  fi
}

deploy_one() { # ip role
  local ip="$1" role="$2"
  say "$role: deploy stack"
  # ensure grafana data dir owned by 472:0 (official image)
  [ "$role" = "mon" ] && ssh $SSH_OPTS "$USER@$ip" "sudo mkdir -p /opt/nama/mon/onetech-data && sudo chown -R 472:0 /opt/nama/mon/onetech-data"
  ssh $SSH_OPTS "$USER@$ip" "sudo bash -c 'cd /opt/nama/$role && bash deploy.sh'"
}

firewall_one() { # ip role
  local ip="$1" role="$2"; [ "$SKIP_FW" = true ] && return 0
  say "$role: apply firewall"
  local u="${ROLE_UFW[$role]}"
  ssh $SSH_OPTS "$USER@$ip" "sudo MGMT_CIDR=$MGMT_CIDR ADMIN_CIDR=$ADMIN_CIDR F5_IP=$F5_IP MON_CIDR=$MON_CIDR MON_IP=$IP_MON STORAGE_IP=$IP_STORAGE AUTH_IP=$IP_AUTH bash /opt/nama/ops/$u"
  # post-firewall alive check (MGMT_CIDR must cover this workstation)
  if ! ssh $SSH_OPTS "$USER@$ip" true 2>/dev/null; then
    echo "WARNING: $role no longer reachable after firewall." >&2
    echo "         Your IP is outside MGMT_CIDR=$MGMT_CIDR. Use console access: sudo ufw disable" >&2
  fi
}

health_one() { # ip role
  local ip="$1" role="$2"
  say "$role: health report"
  ssh $SSH_OPTS "$USER@$ip" "sudo bash /opt/nama/ops/health-report.sh" || true
}

# ---- 4. run: phase A bootstrap, phase B deploy, phase C firewall, phase D health ----
for e in "$IP_MON:mon" "$IP_STORAGE:storage" "$IP_AUTH:auth"; do
  ip="${e%%:*}"; role="${e##*:}"
  provision_one "$ip" "$role"
done

for e in "$IP_MON:mon" "$IP_STORAGE:storage" "$IP_AUTH:auth"; do
  ip="${e%%:*}"; role="${e##*:}"
  deploy_one "$ip" "$role"
done

for e in "$IP_MON:mon" "$IP_STORAGE:storage" "$IP_AUTH:auth"; do
  ip="${e%%:*}"; role="${e##*:}"
  firewall_one "$ip" "$role"
done

for e in "$IP_MON:mon" "$IP_STORAGE:storage" "$IP_AUTH:auth"; do
  ip="${e%%:*}"; role="${e##*:}"
  health_one "$ip" "$role"
done

say "DONE. Machines:"
GF_URL=$(grep -E '^GF_SERVER_ROOT_URL=' "${ROLE_DIR[mon]}/.env" | cut -d= -f2)
KC_URL=$(grep -E '^KC_PUBLIC_URL=' "${ROLE_DIR[mon]}/.env" | cut -d= -f2)
echo "  Direct: https://${IP_MON}:3000   Grafana  (self-signed internal-CA) | https://${IP_AUTH}:8443  Keycloak"
echo "  Public (interim nip.io): ${GF_URL:-GF_SERVER_ROOT_URL unset} -> Grafana | ${KC_URL:-KC_PUBLIC_URL unset} -> Keycloak"
echo "  /opt/nama on each host is the deploy tree — keep it for re-deploy/rollback."
echo "Next manual steps: F5 VIP rewrite + real public certs (design §15 Phase 5) + Keycloak client setup (§6)."