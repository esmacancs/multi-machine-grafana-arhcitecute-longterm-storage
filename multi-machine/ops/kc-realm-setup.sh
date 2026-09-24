#!/bin/bash
# =============================================================================
# Keycloak realm setup: grafana-namawater (admin-cli REST, direct to AUTH VM)
# Creates: realm, grafana-admin/grafana-editor realm roles, roles-scope ID-token
# mapper, confidential OIDC client grafana-nama, users + assignments.
# =============================================================================
set -euo pipefail

BASE="https://10.0.170.115:8443"
REALM="grafana-namawater"
GRAFANA_HOST="grafana.10.0.170.159.nip.io"
GRAFANA_URL="https://${GRAFANA_HOST}:3000"
CLIENT_ID="grafana-nama"

KC_ADMIN="$(cat /mnt/d/New-DATA-After-backup/grafana-key-vmagent-project/multi-machine/machine3-nama-auth-vm/secrets/kc_admin_username)"
KC_ADMIN_PASS="$(cat /mnt/d/New-DATA-After-backup/grafana-key-vmagent-project/multi-machine/machine3-nama-auth-vm/secrets/kc_admin_password)"
CLIENT_SECRET="$(cat /mnt/d/New-DATA-After-backup/grafana-key-vmagent-project/multi-machine/machine1-nama-mon-stack/secrets/grafana_oidc_client_secret)"

py() { python3 -c "$1"; }

echo "== get admin bearer token =="
TOK_FILE="${TMPDIR:-/tmp}/kc_admin_token.json"
curl -ksS --max-time 15 -X POST "$BASE/realms/master/protocol/openid-connect/token" \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "username=${KC_ADMIN}" \
  --data-urlencode "password=${KC_ADMIN_PASS}" > "$TOK_FILE"
TOK="$(py "import json,sys; print(json.load(open('$TOK_FILE'))['access_token'])")"
echo "token OK (len ${#TOK})"
AUTH="Authorization: Bearer $TOK"
CT="Content-Type: application/json"

api() { # method, path, [json]
  local m="$1" p="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -ksS --max-time 20 -X "$m" "$BASE$p" -H "$AUTH" -H "$CT" -d "$body"
  else
    curl -ksS --max-time 20 -X "$m" "$BASE$p" -H "$AUTH"
  fi
}

echo
echo "== 1) realm $REALM =="
if code=$(curl -ksS -o /dev/null -w '%{http_code}' "$BASE/realms/$REALM/.well-known/openid-configuration"); then :; fi
if [ "$code" = "200" ]; then
  echo "realm already exists (skip)"
else
  api POST "/admin/realms" '{"realm":"'$REALM'","enabled":true,"displayName":"NAMA Water Monitoring"}'
  echo "realm created"
fi

echo
echo "== 2) realm roles grafana-admin / grafana-editor =="
for role in grafana-admin grafana-editor; do
  if api GET "/admin/realms/$REALM/roles/$role" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("present" if d.get("name") else "absent")' 2>/dev/null; then :; fi
  v=$(curl -ksS --max-time 20 -o /dev/null -w '%{http_code}' "$BASE/admin/realms/$REALM/roles/$role" -H "$AUTH")
  if [ "$v" = "200" ]; then
    echo "  $role exists"
  else
    api POST "/admin/realms/$REALM/roles" '{"name":"'$role'"}' >/dev/null
    echo "  $role created"
  fi
done

echo
echo "== 3) ensure realm_access.roles lands in ID token (roles scope mapper) =="
ROLES_SCOPE_ID="$(api GET "/admin/realms/$REALM/client-scopes?search=roles" | python3 -c "import sys,json; d=json.load(sys.stdin); print([s['id'] for s in d if s['name']=='roles'][0])")"
echo "  roles scope id=$ROLES_SCOPE_ID"
MAPPER_ID="$(api GET "/admin/realms/$REALM/client-scopes/$ROLES_SCOPE_ID/protocol-mappers/models" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(next((m['id'] for m in d if m.get('protocolMapper','').startswith('oidc') and m.get('name')=='realm roles'), ''))
")"
echo "  realm-roles mapper id=$MAPPER_ID"
if [ -n "$MAPPER_ID" ]; then
  curl -ksS --max-time 20 -X PUT "$BASE/admin/realms/$REALM/client-scopes/$ROLES_SCOPE_ID/protocol-mappers/models/$MAPPER_ID" -H "$AUTH" -H "$CT" -d '{
    "name":"realm roles","protocolMapper":"oidc-realm-role-mapper",
    "protocol":"openid-connect",
    "config":{
      "claim.name":"realm_access","jsonType.label":"String","multivalued":"true",
      "id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"
    }
  }'
  echo "  roles->ID token mapper enabled"
fi

echo
echo "== 4) client $CLIENT_ID =="
CLIENT_UUID="$(api GET "/admin/realms/$REALM/clients?clientId=$CLIENT_ID" | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d[0]['id'] if d else '')
")"
if [ -n "$CLIENT_UUID" ]; then
  echo "  client exists ($CLIENT_UUID), ensure redirect/secret correct"
  curl -ksS --max-time 20 -X PUT "$BASE/admin/realms/$REALM/clients/$CLIENT_UUID" -H "$AUTH" -H "$CT" -d '{
    "clientId":"'$CLIENT_ID'","enabled":true,"protocol":"openid-connect",
    "publicClient":false,"standardFlowEnabled":true,"directAccessGrantsEnabled":true,
    "redirectUris":["'$GRAFANA_URL'/login/generic_oauth"],
    "webOrigins":["'$GRAFANA_URL'"],
    "secret":"'$CLIENT_SECRET'",
    "attributes":{"post.logout.redirect.uris":"+"}
  }'
  echo "  client updated"
else
  CLIENT_UUID="$(api POST "/admin/realms/$REALM/clients" '{
    "clientId":"'$CLIENT_ID'","enabled":true,"protocol":"openid-connect",
    "publicClient":false,"standardFlowEnabled":true,"directAccessGrantsEnabled":true,
    "redirectUris":["'$GRAFANA_URL'/login/generic_oauth"],
    "webOrigins":["'$GRAFANA_URL'"],
    "secret":"'$CLIENT_SECRET'",
    "attributes":{"post.logout.redirect.uris":"+"}
  }' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['id'])")"
  echo "  client created ($CLIENT_UUID)"
fi

echo
echo "== 5) user esmacan (grafana-admin) =="
ESM_UID="$(api GET "/admin/realms/$REALM/users?username=esmacan&exact=true" | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d[0]['id'] if d else '')
")"
if [ -n "$ESM_UID" ]; then echo "  esmacan exists ($ESM_UID)"; else
  ESM_PASS="$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(20)))')"
  ESM_UID="$(api POST "/admin/realms/$REALM/users" '{
    "username":"esmacan","enabled":true,"emailVerified":true,
    "email":"esmacan@otech.om","firstName":"Esmacan","lastName":"(grafana admin)",
    "credentials":[{"type":"password","value":"'$ESM_PASS'","temporary":false}]
  }' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['id'])")"
  echo "$ESM_PASS" > "${TMPDIR:-/tmp}/esmacan_pw"
  echo "  esmacan created ($ESM_UID), pw->" "${TMPDIR:-/tmp}/esmacan_pw"
fi

echo
echo "== 6) assign grafana-admin to esmacan =="
ADMIN_ROLE_ID="$(api GET "/admin/realms/$REALM/roles/grafana-admin" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")"
api POST "/admin/realms/$REALM/users/$ESM_UID/role-mappings/realm" '[{"id":"'$ADMIN_ROLE_ID'","name":"grafana-admin"}]' >/dev/null
echo "  assigned"

echo
echo "== verifications =="
echo "realm discovery: $(curl -ksS -o /dev/null -w '%{http_code}' "$BASE/realms/$REALM/.well-known/openid-configuration")"
echo "realm info: $(curl -ksS "$BASE/realms/$REALM/.well-known/openid-configuration" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['issuer'], '| token_endpoint:', d['token_endpoint'])")"
echo "client secret matches: $(curl -ksS "$BASE/admin/realms/$REALM/clients/$CLIENT_UUID/client-secret" -H "$AUTH" | python3 -c "
import sys,json
print('OK' if json.load(sys.stdin)['value']=='$CLIENT_SECRET' else 'MISMATCH')
")"
echo "esmacan roles:"
api GET "/admin/realms/$REALM/users/$ESM_UID/role-mappings/realm" | python3 -c "
import sys,json
for r in json.load(sys.stdin): print('  -', r['name'])
"
echo
echo "== ID-token claim check (password grant) =="
if [ -f "${TMPDIR:-/tmp}/esmacan_pw" ]; then
  ESM_PASS="$(cat ${TMPDIR:-/tmp}/esmacan_pw)"
  curl -ksS --max-time 15 -X POST "$BASE/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "client_secret=$CLIENT_SECRET" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "username=esmacan" \
    --data-urlencode "password=$ESM_PASS" \
    --data-urlencode "scope=openid profile email" > "${TMPDIR:-/tmp}/esmacan_token.json"
  python3 - <<'PY'
import json,base64
d=json.load(open("/tmp/esmacan_token.json"))
def decode(tok):
    b=tok.split(".")[1]; b+= "="*((4-len(b)%4)%4)
    return json.loads(base64.urlsafe_b64decode(b))
idtok=decode(d["id_token"])
print("id_token.email:", idtok.get("email"))
print("id_token.realm_access:", json.dumps(idtok.get("realm_access")))
print("Grafana role path input OK" if idtok.get("realm_access",{}).get("roles") and "grafana-admin" in idtok["realm_access"]["roles"] else "!!! realm_access.roles missing from ID token !!!")
PY
fi
echo
echo "DONE"