#!/bin/bash
# =====================================================================
#  Single-machine deploy script
#  - loads secrets (from .env.gpg if present, else .env)
#  - renders vmauth.yml from the .tpl template
#  - starts the full stack
# =====================================================================
set -e

set -a
if [ -f .env.gpg ]; then
  eval "$(gpg -d .env.gpg)"
else
  # shellcheck disable=SC1091
  source .env
fi
set +a

envsubst < vmauth.yml.tpl > vmauth.yml
chmod 600 vmauth.yml

docker compose up -d

echo
echo "Stack is starting. Check:"
echo "  docker compose ps"
echo "  docker logs -f traefik"
echo "  docker logs -f keycloak"