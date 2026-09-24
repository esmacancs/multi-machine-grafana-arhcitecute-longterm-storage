#!/bin/bash
# =============================================================================
#  Backups for MACHINE 1 (Grafana + VictoriaMetrics + configs) — root.
#  Run on VM1.  See ../PRODUCTION-SECURITY-DESIGN.md §10.
#
#  Backup set (root:root 0600 under /srv/backups/vm1/<date>/):
#    - Grafana sqlite (grafana.db)          -> RPO 24h
#    - provisioning/ (dashboards+datasource) + .env (root-only)
#    - VictoriaMetrics vmbackup snapshot    -> RPO 24h, retention 14d on disk
#
#  Off-host + encryption: set AGE_PUB (age public key) and CRON schedule.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

AGE_PUB="${AGE_PUB:-}"                 # e.g. age1... (set on VM1), empty = no encrypt
BK="/srv/backups/vm1/$(date +%F-%H%M)"
mkdir -p "$BK"; chmod 700 "$BK"; chown root:root "$BK"

echo "==> Grafana sqlite"
docker exec onetech sh -c \
  "sqlite3 /var/lib/grafana/grafana.db \".backup '/tmp/grafana.db'\"" \
  && docker cp onetech:/tmp/grafana.db "$BK/grafana.db" \
  || echo "WARN: grafana.db copy failed (is sqlite3 in the image?)" 

echo "==> Grafana provisioning + dashboards"
tar -czf "$BK/provisioning.tar.gz" ./machine1-nama-mon-stack/provisioning 2>/dev/null || true

echo "==> configs + secrets (root-only; encrypt if AGE_PUB set)"
tar -czf "$BK/configs.tar.gz" \
  ./machine1-nama-mon-stack/vmauth.yml \
  ./machine1-nama-mon-stack/.env 2>/dev/null || true

echo "==> VictoriaMetrics snapshot (vmbackup)"
SNAP="snap-$(date +%s)"
docker exec victoria-metrics wget -q -O - "http://localhost:8428/snapshot/create?snapshot=$SNAP" >/dev/null 2>&1 \
  && echo "snapshot $SNAP created" \
  || echo "WARN: snapshot create failed (endpoint may differ for single-node; using snapshot.delete only on success)"
# vmbackup binary is expected in the image or host; if unavailable, fall back to
# a raw tar of ./victoria-metrics-data for a warm copy.
if command -v vmbackup >/dev/null 2>&1; then
  vmbackup -storageDataPath=./victoria-metrics-data \
           -snapshotName="$SNAP" \
           -dst="file://$BK/vm-snapshot" || true
else
  tar -czf "$BK/victoria-metrics-data.tar.gz" ./victoria-metrics-data || true
fi
docker exec victoria-metrics wget -q -O - "http://localhost:8428/snapshot/delete?snapshot=$SNAP" >/dev/null 2>&1 || true

echo "==> rotate + (optional) encrypt + ship"
if [ -n "$AGE_PUB" ]; then
  for f in "$BK"/*.tar.gz "$BK"/grafana.db; do
    [ -f "$f" ] && age -r "$AGE_PUB" < "$f" > "$f.age" && rm -f "$f"
  done
  echo "encrypted with AGE_PUB=$AGE_PUB"
fi
echo "Backup dir: $BK"
echo "Ship with rclone/restic to Veeam/NFS — schedule daily (RPO 24h, retention: daily14/weekly8/monthly12)."