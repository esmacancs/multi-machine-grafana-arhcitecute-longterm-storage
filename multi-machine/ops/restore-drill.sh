#!/bin/bash
# =============================================================================
#  Restore drill — verifies the backup artifacts WITHOUT touching production.
#  Run on VM1 (Grafana/VM path) and VM3 (Keycloak path); set BK=<dir>.
#  See ../PRODUCTION-SECURITY-DESIGN.md §10 (quarterly).
# =============================================================================
set -euo pipefail
BK="${BK:?Usage: BK=/srv/backups/<vm>/<stamp> ./restore-drill.sh}"

echo "==> artifacts present"
ls -l "$BK"

echo "==> Grafana: verify sqlite integrity on a COPY"
if [ -f "$BK/grafana.db" ]; then
  cp "$BK/grafana.db" /tmp/grafana-drill.db
  sqlite3 /tmp/grafana-drill.db "PRAGMA integrity_check;" && echo "grafana.db OK"
  rm -f /tmp/grafana-drill.db
else
  echo "no grafana.db (skipped)"
fi

echo "==> VictoriaMetrics: list archive contents"
for f in "$BK"/victoria-metrics-data.tar.gz; do
  [ -f "$f" ] && tar -tzf "$f" >/dev/null && echo "archive OK: $f"
done
[ -d "$BK/vm-snapshot" ] && echo "vm-snapshot dir OK: $BK/vm-snapshot"

echo "==> Keycloak: verify pg_dump header (VM3 path)"
for f in "$BK"/keycloak.dump; do
  [ -f "$f" ] && file "$f" | grep -qi postgres && echo "pg_dump OK: $f"
done

echo "==> configs"
for f in "$BK"/configs.tar.gz "$BK"/provisioning.tar.gz; do
  [ -f "$f" ] && tar -tzf "$f" >/dev/null && echo "tar OK: $f"
done

echo
echo "Drill PASSED if every existing artifact verified. Full restore requires a scratch VM."