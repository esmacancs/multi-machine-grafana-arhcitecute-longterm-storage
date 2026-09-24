#!/bin/bash
# =============================================================================
#  MACHINE 1 deploy script (nama-mon-stack)
#  - loads the non-secret .env
#  - exports secret values from ./secrets/ (root-only) into the render env
#  - renders vmauth.yml and the Grafana datasource (chmod 600)
#  - starts the stack
#  Run as root:  sudo ./deploy.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# --- load .env (non-secret config) ---
set -a
# shellcheck disable=SC1091
source .env
set +a

SECRETS_DIR=./secrets
if [ ! -d "$SECRETS_DIR" ]; then
  echo "ERROR: $SECRETS_DIR not found. Generate secrets first: ../ops/gen-secrets.sh" >&2
  exit 1
fi

# --- export secrets for envsubst (values are read into the rendered files) ---
# vmauth
export VMAUTH_VMAGENT_USERNAME="$(cat "$SECRETS_DIR/vmauth_vmagent_username")"
export VMAUTH_VMAGENT_PASSWORD="$(cat "$SECRETS_DIR/vmauth_vmagent_password")"
export VMAUTH_GRAFANA_USERNAME="$(cat "$SECRETS_DIR/vmauth_grafana_username")"
export VMAUTH_GRAFANA_PASSWORD="$(cat "$SECRETS_DIR/vmauth_grafana_password")"

# Grafana provisioning reads password + CA from files (see datasource tpl).
# Exporting the literal $__file{...} refs lets envsubst substitute them safely.
export VMAUTH_GRAFANA_PASSWORD_FILE_REF='$__file{/run/secrets/vmauth_grafana_password}'
export VMAUTH_CA_FILE_REF='$__file{/run/secrets/vmauth_ca.pem}'

# --- render configs ---
command -v envsubst >/dev/null || { echo "ERROR: envsubst (gettext-base) required"; exit 1; }

envsubst < vmauth.yml.tpl > vmauth.yml
chmod 600 vmauth.yml

envsubst < provisioning/datasources/victoriametrics.yml.tpl \
         > provisioning/datasources/victoriametrics.yml
chmod 640 provisioning/datasources/victoriametrics.yml   # grafana runs as 472:0 — must be group-readable

# --- sanity checks ---
for f in grafana_admin_password grafana_oidc_client_secret smtp_password \
         vmauth_tls.crt vmauth_tls.key vmauth_ca.pem \
         grafana_tls.crt grafana_tls.key; do
  [ -s "$SECRETS_DIR/$f" ] || { echo "ERROR: missing secret $SECRETS_DIR/$f" >&2; exit 1; }
done

if grep -rqE '@sha256:[a-f0-9]{40,}' docker-compose.yml; then
  :
else
  echo "WARNING: no image digests pinned. Run ../ops/pin-images.sh before production." >&2
fi

# --- up ---
docker compose up -d

echo
echo "Stack is starting. Check:"
echo "  docker compose ps"
echo "  docker logs -f vmauth"
echo "  docker logs -f onetech"
echo
echo "Validate:"
echo "  curl -su vmagent:<pw> https://vmauth:8427/api/v1/query?query=up   (write user = 200)"
echo "  ss -lntup   (expect 3000/8427/9100 bound to ${MON_IP:-your-host-IP} only, no 8428)"