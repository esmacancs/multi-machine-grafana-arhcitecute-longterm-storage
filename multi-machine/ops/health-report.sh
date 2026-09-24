#!/bin/bash
# =============================================================================
#  Platform health report — run on any VM (or via cron). Prints a compact
#  status summary; can be piped to the node-exporter textfile collector or
#  vmagent push.  See ../PRODUCTION-SECURITY-DESIGN.md §11.
# =============================================================================
set -euo pipefail

echo "=== docker ==="
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true

echo
echo "=== listening ports (should be: 22 + LAN-bound 3000/8427/9100 or 8080/8443/9000/9100) ==="
ss -lntup 2>/dev/null | sed 1d || netstat -lntup 2>/dev/null || true

echo
echo "=== disk (alert if any >80%) ==="
df -hP | awk 'NR==1 || $5+0 > 80'

echo
echo "=== firewall ==="
ufw status 2>/dev/null || echo "ufw not active"

echo
echo "=== fail2ban ==="
fail2ban-client status 2>/dev/null || true

echo
echo "=== health endpoints ==="
# vmauth (TLS, self-signed) / VM internal
curl -sk --max-time 3 https://127.0.0.1:8427/health && echo "vmauth health OK" || true
curl -s  --max-time 3 http://127.0.0.1:8428/health  && echo "victoria-metrics health OK" || true
# grafana (HTTPS via nip.io leaf; self-signed internal CA -> -k)
# NOTE: docker-proxy binds the VM IP (not 127.0.0.1), so resolve the local IP.
GF_IP=$(ip -4 addr show | awk '$1=="inet" && $2 !~ /^127\./ {print $2; exit}' | cut -d/ -f1)
curl -sk --max-time 3 "https://${GF_IP:-127.0.0.1}:3000/api/health" | head -c 300 || true

echo
echo "=== recent container errors (last 50 lines each) ==="
for c in $(docker ps --format '{{.Names}}'); do
  err=$(docker logs --tail 50 "$c" 2>&1 | grep -Ei 'error|fatal|panic' | tail -3 || true)
  [ -n "$err" ] && { echo "--- $c ---"; echo "$err"; }
done

echo
echo "Done. Schedule: */5 * * * * root /path/ops/health-report.sh > /var/log/nama-health.log 2>&1"