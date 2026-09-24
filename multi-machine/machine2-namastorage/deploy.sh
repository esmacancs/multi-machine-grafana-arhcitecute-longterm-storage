#!/bin/bash
# =============================================================================
#  MACHINE 2 deploy script (namastorage)
#  - loads the non-secret .env (contains the provider-assigned static IPs)
#  - renders scrape.yml from scrape.yml.tpl (chmod 600)
#  - starts the stack
#  Run as root:  sudo ./deploy.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# --- load .env (non-secret config + static IPs) ---
set -a
# shellcheck disable=SC1091
source .env
set +a

command -v envsubst >/dev/null || { echo "ERROR: envsubst (gettext-base) required"; exit 1; }

# --- render scrape config ---
envsubst < scrape.yml.tpl > scrape.yml
chmod 600 scrape.yml

# --- sanity: IPs set ---
for v in STORAGE_IP VMAUTH_IP MON_IP AUTH_IP; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || { echo "ERROR: $v not set in .env (provider-assigned static IP)"; exit 1; }
done

# --- secrets present ---
for f in vmagent_user vmagent_pass vmauth_ca.pem; do
  [ -s "secrets/$f" ] || { echo "ERROR: missing secret secrets/$f"; exit 1; }
done

# --- up ---
docker compose up -d

echo
echo "Stack starting. Validate:"
echo "  docker compose ps"
echo "  grep -c remoteWrite: ; ss -lntup   (expect 9100/9115/9710 on ${STORAGE_IP}; 8429/9091 loopback only)"