#!/bin/bash
# =============================================================================
#  Internal Certificate Authority + vmauth server certificate for VM1.
#
#  Creates (root-only 0700/0600):
#    machine1-nama-mon-stack/secrets/
#      vmauth_ca.pem                 # CA certificate (distribute to VM2 + datasource)
#      vmauth_tls.crt  vmauth_tls.key# server cert/key for vmauth (SAN: nama-mon-stack)
#
#  vmauth listens on ${VMAUTH_IP:-172.29.50.2}:8427; vmagent verifies the connection with
#  -remoteWrite.tlsCAFile + -remoteWrite.tlsServerName=nama-mon-stack.
#
#  Renewal: the leaf is valid 1y; rerun with `--renew` before expiry
#  (watch probe_ssl_earliest_cert_expiry in Grafana).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
SEC=machine1-nama-mon-stack/secrets
mkdir -p "$SEC"; chmod 700 "$SEC"

if [ "${1:-}" = "--renew" ]; then
  echo "Renewing leaf (CA kept)..." 
else
  [ -f "$SEC/vmauth_ca.pem" ] && { echo "CA exists: $SEC/vmauth_ca.pem (use --renew for leaf rotation)"; }
fi

umask 077

# ---- CA (kept unless missing) ----
if [ ! -s "$SEC/vmauth_ca.pem" ] || [ ! -s "$SEC/vmauth_ca.key" ]; then
  openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
    -keyout "$SEC/vmauth_ca.key" -out "$SEC/vmauth_ca.pem" \
    -subj "/C=OM/O=Otech/OU=Monitoring/CN=NAMA Monitoring Internal CA"
  echo "CA created."
fi

# ---- leaf key + csr + sign (valid 1y, version-safe SAN) ----
openssl req -newkey rsa:3072 -nodes \
  -keyout "$SEC/vmauth_tls.key" -out /tmp/vmauth_tls.csr \
  -subj "/C=OM/O=Otech/OU=Monitoring/CN=nama-mon-stack"

openssl x509 -req -sha256 -days 365 \
  -in /tmp/vmauth_tls.csr \
  -CA "$SEC/vmauth_ca.pem" -CAkey "$SEC/vmauth_ca.key" -CAcreateserial \
  -out "$SEC/vmauth_tls.crt" \
  -extfile <(printf 'subjectAltName=DNS:nama-mon-stack,DNS:nama-mon-stack.otech.om,DNS:vmauth,IP:%s,IP:127.0.0.1' "${VMAUTH_IP:-172.29.50.2}")

rm -f /tmp/vmauth_tls.csr

if [ "$(id -u)" -eq 0 ]; then
  chown root:root "$SEC/vmauth_ca.pem" "$SEC/vmauth_ca.key" "$SEC/vmauth_tls.crt" "$SEC/vmauth_tls.key"
fi
chmod 600 "$SEC/vmauth_ca.key" "$SEC/vmauth_tls.key"
chmod 644 "$SEC/vmauth_ca.pem" "$SEC/vmauth_tls.crt"   # CA + cert are public by nature

echo
echo "Verify:"
echo "  openssl verify -CAfile $SEC/vmauth_ca.pem $SEC/vmauth_tls.crt"
echo "  openssl x509 -in $SEC/vmauth_tls.crt -noout -text | grep -A1 'Subject Alternative Name'"
echo
echo "Distribute \$SEC/vmauth_ca.pem to:"
echo "  - machine2-namastorage/secrets/vmauth_ca.pem   (vmagent remote write)"
echo "  - machine1 .../provisioning datasource (mounted to Grafana as /run/secrets/vmauth_ca.pem)"