#!/bin/bash
# =============================================================================
#  Backups for MACHINE 3 (Keycloak PostgreSQL + realm) — root. Run on VM3.
#  See ../PRODUCTION-SECURITY-DESIGN.md §10.
#    - pg_dump -Fc (full DB, RPO 24h)
#    - Keycloak realm export JSON (deterministic, weekly)
#  Encrypt with AGE_PUB (age public key) if set; ship off-host daily.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
AGE_PUB="${AGE_PUB:-}"

BK="/srv/backups/vm3/$(date +%F-%H%M)"
mkdir -p "$BK"; chmod 700 "$BK"; chown root:root "$BK"

echo "==> pg_dump (keycloak DB)"
docker exec keycloak-db pg_dump -U keycloak -Fc -d keycloak > "$BK/keycloak.dump"

echo "==> Keycloak realm export"
docker exec keycloak sh -c '/opt/keycloak/bin/kc.sh export --realm grafana-namawater --file /tmp/realm.json' \
  && docker cp keycloak:/tmp/realm.json "$BK/realm-grafana-namawater.json" \
  || echo "WARN: realm export failed (try `docker exec keycloak cat /tmp/realm.json`)"

echo "==> rotate + (optional) encrypt + ship"
if [ -n "$AGE_PUB" ]; then
  for f in "$BK"/*.dump "$BK"/*.json; do
    [ -f "$f" ] && age -r "$AGE_PUB" < "$f" > "$f.age" && rm -f "$f"
  done
fi
echo "Backup dir: $BK"
echo "Restore: docker cp <file> keycloak-db:/tmp/ && docker exec keycloak-db pg_restore -U keycloak -d keycloak /tmp/keycloak.dump"