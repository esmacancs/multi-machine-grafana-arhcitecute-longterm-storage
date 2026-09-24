#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
[ -d ./secrets ] || { echo "ERROR: ./secrets missing — run ../ops/gen-secrets.sh first"; exit 1; }
for f in kc_db_password kc_admin_username kc_admin_password kc_tls.crt kc_tls.key; do
  [ -s "secrets/$f" ] || { echo "ERROR: missing secret secrets/$f"; exit 1; }
done

# postgres image runs as uid 999; data dir may be root-owned after rsync/tar
mkdir -p ./postgres
chown -R 999:999 ./postgres

docker compose up -d
echo
echo "Stack starting. Validate:"
echo "  docker compose ps"
echo "  curl -s http://${AUTH_IP:-<ip>}:9000/health/ready"
