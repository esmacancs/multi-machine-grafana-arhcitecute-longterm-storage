#!/bin/bash
# =============================================================================
#  Internal CA leaf certs for the nip.io public hostnames (interim, no F5 yet).
#
#  Uses the SAME internal CA created by gen-ca.sh (machine1 secrets).
#  Creates (root-only):
#    machine1-nama-mon-stack/secrets/grafana_tls.{crt,key}
#        SAN: DNS:grafana.<MON_IP>.nip.io, IP:<MON_IP>, IP:127.0.0.1
#    machine3-nama-auth-vm/secrets/kc_tls.{crt,key}
#        SAN: DNS:auth.<AUTH_IP>.nip.io,    IP:<AUTH_IP>, IP:127.0.0.1
#
#  Serves two purposes:
#    * Grafana serves HTTPS directly (GF_SERVER_PROTOCOL=https, cert via secrets)
#      at https://grafana.<MON_IP>.nip.io:3000
#    * Keycloak serves HTTPS directly (KC_HTTPS_CERTIFICATE_FILE=...)
#      at https://auth.<AUTH_IP>.nip.io:8443   (KC_HTTPS_PORT=8443)
#
#  Both are signed by the internal CA so Grafana's OIDC -> Keycloak TLS chain is
#  trusted by Grafana (mount CA via GF_AUTH_GENERIC_OAUTH_TLS_CLIENT_CA) for
#  the token/userinfo exchange. Browsers will still warn (internal CA unknown)
#  until real public certs + F5 arrive — acceptable for the nip.io interim phase.
#
#  Renewal: leaves are valid 1y; rerun to regenerate (keys rotate too).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

CAPEM=machine1-nama-mon-stack/secrets/vmauth_ca.pem
CAKEY=machine1-nama-mon-stack/secrets/vmauth_ca.key
[ -s "$CAPEM" ] && [ -s "$CAKEY" ] || { echo "FATAL: internal CA missing. Run ops/gen-ca.sh first."; exit 1; }

mkdir -p machine1-nama-mon-stack/secrets machine3-nama-auth-vm/secrets
umask 077

mk_leaf() { # sec_dir hostname san  →  writes <sec>/<prefix>_tls.{crt,key}
  local sec="$1" prefix="$2" host="$3" san="$4"
  local key="$sec/${prefix}_tls.key" crt="$sec/${prefix}_tls.crt"
  [ -s "$crt" ] && { echo "exists: $crt (skip)"; return; }
  openssl req -newkey rsa:3072 -nodes \
    -keyout "$key" -out /tmp/${prefix}_tls.csr \
    -subj "/C=OM/O=Otech/OU=Monitoring/CN=${host}"
  openssl x509 -req -sha256 -days 365 \
    -in /tmp/${prefix}_tls.csr \
    -CA "$CAPEM" -CAkey "$CAKEY" -CAcreateserial \
    -out /tmp/${prefix}_tls.crt \
    -extfile <(printf 'subjectAltName=%s' "$san")
  # full chain: leaf + internal CA (so clients that trust the CA build the chain)
  cat "/tmp/${prefix}_tls.crt" "$CAPEM" > "$crt"
  rm -f "/tmp/${prefix}_tls.csr" "/tmp/${prefix}_tls.crt"
}

# grafana leaf (machine1)
mk_leaf machine1-nama-mon-stack/secrets grafana "grafana.${MON_IP:-172.29.50.2}.nip.io" \
  "DNS:grafana.${MON_IP:-172.29.50.2}.nip.io,DNS:grafana,IP:${MON_IP:-172.29.50.2},IP:127.0.0.1"

# keycloak leaf (machine3) — file is named kc_tls.* to match compose secret names
mkdir -p machine3-nama-auth-vm/secrets
[ -s machine3-nama-auth-vm/secrets/kc_tls.crt ] && echo "exists: machine3-nama-auth-vm/secrets/kc_tls.crt (skip)" || {
  openssl req -newkey rsa:3072 -nodes \
    -keyout machine3-nama-auth-vm/secrets/kc_tls.key -out /tmp/kc_tls.csr \
    -subj "/C=OM/O=Otech/OU=Monitoring/CN=auth.${AUTH_IP:-172.29.50.4}.nip.io"
  openssl x509 -req -sha256 -days 365 \
    -in /tmp/kc_tls.csr \
    -CA "$CAPEM" -CAkey "$CAKEY" -CAcreateserial \
    -out /tmp/kc_tls.crt \
    -extfile <(printf 'subjectAltName=DNS:auth.%s.nip.io,DNS:auth,IP:%s,IP:127.0.0.1' "${AUTH_IP:-172.29.50.4}" "${AUTH_IP:-172.29.50.4}")
  cat /tmp/kc_tls.crt "$CAPEM" > machine3-nama-auth-vm/secrets/kc_tls.crt
  rm -f /tmp/kc_tls.csr /tmp/kc_tls.crt
}

if [ "$(id -u)" -eq 0 ]; then
  chown root:root machine1-nama-mon-stack/secrets/grafana_tls.crt machine1-nama-mon-stack/secrets/grafana_tls.key \
                  machine3-nama-auth-vm/secrets/kc_tls.crt machine3-nama-auth-vm/secrets/kc_tls.key
fi
chmod 600 machine1-nama-mon-stack/secrets/grafana_tls.key machine3-nama-auth-vm/secrets/kc_tls.key
chmod 644 machine1-nama-mon-stack/secrets/grafana_tls.crt machine3-nama-auth-vm/secrets/kc_tls.crt

echo
echo "Verify:"
echo "  openssl verify -CAfile $CAPEM machine1-nama-mon-stack/secrets/grafana_tls.crt"
echo "  openssl verify -CAfile $CAPEM machine3-nama-auth-vm/secrets/kc_tls.crt"
echo "  openssl x509 -in machine1-nama-mon-stack/secrets/grafana_tls.crt -noout -text | grep -A1 'Subject Alternative Name'"
echo "  openssl x509 -in machine3-nama-auth-vm/secrets/kc_tls.crt -noout -text | grep -A1 'Subject Alternative Name'"