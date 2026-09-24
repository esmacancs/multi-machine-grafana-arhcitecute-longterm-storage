#!/bin/bash
# =============================================================================
#  Rotate a single secret + redeploy the affected service. Root.
#    ./rotate-secrets.sh <target>
#  Targets:
#    grafana-admin        - regenerate secrets/grafana_admin_password -> restart onetech
#    grafana-oidc         - regenerate grafana_oidc_client_secret, print for KC client update
#    smtp                 - regenerate smtp_password -> restart onetech
#    vmauth-grafana       - regenerate vmauth_grafana_password -> re-render + restart vmauth
#    vmauth-vmagent       - regenerate vmauth_vmagent_password -> re-render + restart vmauth
#    kc-admin             - regenerate kc_admin_password (then kc.sh reset-password)
#    kc-db                - regenerate kc_db_password (then ALTER ROLE + restart)
#    vmagent              - regenerate vmagent_pass -> restart VM2 vmagent
#
#  See ../PRODUCTION-SECURITY-DESIGN.md §10 / §17 (rotation).
#  ALWAYS rotate the OLD value everywhere first: Grafana OIDC secret lives in
#  the Keycloak realm client, KC DB password lives in PostgreSQL, etc.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

T="${1:-}"
[ -z "$T" ] && { grep -E '^#    ' "$0" | sed 's/^#  *//'; exit 1; }

rand() { openssl rand -base64 24 | tr -d '\n'; }
set_secret() {  # set_secret <dir> <file>
  printf '%s' "$(rand)" > "$2/secrets/$1"; chown root:root "$2/secrets/$1"; chmod 600 "$2/secrets/$1"
  echo "rotated: $2/secrets/$1"
}

case "$T" in
  grafana-admin)
    set_secret grafana_admin_password machine1-nama-mon-stack
    docker compose -f machine1-nama-mon-stack/docker-compose.yml restart onetech ;;

  grafana-oidc)
    set_secret grafana_oidc_client_secret machine1-nama-mon-stack
    echo "!! Copy the new value into Keycloak client 'grafana-nama' (Client secret),"
    echo "   then restart onetech:"
    echo "   docker compose -f machine1-nama-mon-stack/docker-compose.yml restart onetech" ;;

  smtp)
    set_secret smtp_password machine1-nama-mon-stack
    docker compose -f machine1-nama-mon-stack/docker-compose.yml restart onetech ;;

  vmauth-grafana|vmauth-vmagent)
    set_secret "vmauth_${T#vmauth-}_password" machine1-nama-mon-stack
    (cd machine1-nama-mon-stack && ./deploy.sh) ;;

  kc-admin)
    set_secret kc_admin_password machine3-nama-auth-vm
    echo "!! Also run inside the container:"
    echo "   docker exec -it keycloak /opt/keycloak/bin/kc.sh reset-password -u <admin-user>" ;;

  kc-db)
    set_secret kc_db_password machine3-nama-auth-vm
    echo "!! Also run:"
    echo "   docker exec -e PGPASSWORD=\$(cat machine3-nama-auth-vm/secrets/kc_db_password) keycloak-db \\"
    echo "     psql -U keycloak -c \"ALTER ROLE keycloak WITH PASSWORD '<new>';\""
    echo "   docker compose -f machine3-nama-auth-vm/docker-compose.yml restart keycloak" ;;

  vmagent)
    set_secret vmagent_pass machine2-namastorage
    docker compose -f machine2-namastorage/docker-compose.yml restart vmagent ;;

  *) echo "unknown target: $T" >&2; exit 1 ;;
esac

echo "Rotation target processed. Update the CONSUMING side (Keycloak client / DB / SMTP) before cutting over."