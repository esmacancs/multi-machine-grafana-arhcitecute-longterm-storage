#!/bin/bash
# =============================================================================
#  Generate all secrets for the hardened multi-machine deployment.
#
#  Usage:
#    sudo ./gen-secrets.sh            # generate into <machine>/secrets/
#    sudo ./gen-secrets.sh --print    # also dump generated values to stdout
#
#  Output layout (mirrors ../PRODUCTION-SECURITY-DESIGN.md §4.4):
#    machine1-nama-mon-stack/secrets/{grafana_admin_password,
#        grafana_oidc_client_secret, smtp_password, vmauth_*_{username,password}}
#    machine2-namastorage/secrets/{vmagent_user, vmagent_pass}
#    machine3-nama-auth-vm/secrets/{kc_db_password, kc_admin_username, kc_admin_password}
#  TLS material (CA + vmauth cert) comes from gen-ca.sh.
#
#  Each file is root:root 0600 under a 0700 secrets/ dir. The generated values
#  MUST be distributed to the Keycloak realm / Grafana / SMTP as needed.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

PRINT=0
[ "${1:-}" = "--print" ] && PRINT=1

rand_hex() { openssl rand -hex $(( ${1:-16} )); }
rand_b64() { openssl rand -base64 $(( ${1:-24} )); }

gen() {  # gen <dir> <file> <producer>
  local dir="$1" file="$2" producer="$3"
  mkdir -p "$dir/secrets"; chmod 700 "$dir/secrets"
  local out="$dir/secrets/$file"
  if [ -s "$out" ]; then
    echo "  keep existing: $out"
    return
  fi
  [ "$producer" = "hex" ] && eval "printf '%s' \"\$(rand_hex)\"" > "$out"
  [ "$producer" = "b64" ] && eval "printf '%s\\n' \"\$(rand_b64)\"" > "$out"
  if [ "$(id -u)" -eq 0 ]; then chown root:root "$out"; fi
  chmod 600 "$out"
  echo "  generated:     $out"
  [ "$PRINT" -eq 1 ] && echo "    -> $(cat "$out")"
  return 0
}

# ---- machine1 (nama-mon-stack) ----
echo "[machine1] nama-mon-stack"
gen machine1-nama-mon-stack grafana_admin_password        b64 24
gen machine1-nama-mon-stack grafana_oidc_client_secret    b64 32
gen machine1-nama-mon-stack smtp_password                 b64 24

# vmagent <-> vmauth share ONE credential pair: generate it once and place it
# in both tree (machine1 vmauth_* , machine2 vmagent_*), keeping existing values.
m1u=machine1-nama-mon-stack/secrets/vmauth_vmagent_username
m1p=machine1-nama-mon-stack/secrets/vmauth_vmagent_password
m2u=machine2-namastorage/secrets/vmagent_user
m2p=machine2-namastorage/secrets/vmagent_pass
if [ -s "$m1u" ]; then
  echo "  keep existing: $m1u"
else
  mkdir -p "$(dirname "$m1u")" "$(dirname "$m2u")"
  { chmod 700 "$(dirname "$m1u")"; chmod 700 "$(dirname "$m2u")"; } || true
  eval "printf '%s' \"\$(rand_hex)\"" > "$m1u"
  cp "$m1u" "$m2u"
  chmod 600 "$m1u" "$m2u"
  echo "  generated:     $m1u (shared with $m2u)"
fi
if [ -s "$m1p" ]; then
  echo "  keep existing: $m1p"
else
  eval "printf '%s\\n' \"\$(rand_b64)\"" > "$m1p"
  cp "$m1p" "$m2p"
  chmod 600 "$m1p" "$m2p"
  echo "  generated:     $m1p (shared with $m2p)"
fi

gen machine1-nama-mon-stack vmauth_grafana_username       hex 8
gen machine1-nama-mon-stack vmauth_grafana_password       b64 24

# ---- machine2 (namastorage) vmagent creds = shared pair above ----
echo "[machine2] namastorage"
# vmagent_user / vmagent_pass are placed by the machine1 block above.

# ---- machine3 (nama-auth-vm) ----
echo "[machine3] nama-auth-vm"
gen machine3-nama-auth-vm kc_db_password                  b64 24
gen machine3-nama-auth-vm kc_admin_username               hex 8
gen machine3-nama-auth-vm kc_admin_password               b64 24

echo
echo "Done. Next steps:"
echo "  sudo ./ops/gen-ca.sh            # internal CA + vmauth TLS cert (machine1)"
echo "  cp secrets to each VM (scp -o ...), then run the machine deploy.sh"
echo "  Provision grafana_oidc_client_secret + vmauth users into Keycloak/realm"
echo "  NEVER commit these files (multi-machine/*/secrets is git-ignored)."