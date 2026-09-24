#!/bin/bash
set -euo pipefail
BASE="https://10.0.170.115:8443"
REALM="grafana-namawater"
GRAFANA_URL="https://grafana.10.0.170.159.nip.io:3000"
CLIENT_ID="grafana-nama"
KC_ADMIN="$(cat /mnt/d/New-DATA-After-backup/grafana-key-vmagent-project/multi-machine/machine3-nama-auth-vm/secrets/kc_admin_username)"
KC_ADMIN_PASS="$(cat /mnt/d/New-DATA-After-backup/grafana-key-vmagent-project/multi-machine/machine3-nama-auth-vm/secrets/kc_admin_password)"
CLIENT_SECRET="$(cat /mnt/d/New-DATA-After-backup/grafana-key-vmagent-project/multi-machine/machine1-nama-mon-stack/secrets/grafana_oidc_client_secret)"

curl -ksS -X POST "$BASE/realms/master/protocol/openid-connect/token" \
  --data-urlencode "client_id=admin-cli" --data-urlencode "grant_type=password" \
  --data-urlencode "username=${KC_ADMIN}" --data-urlencode "password=${KC_ADMIN_PASS}" > /tmp/tok.json
TOK="$(python3 -c 'import json;print(json.load(open("/tmp/tok.json"))["access_token"])')"
AUTH="Authorization: Bearer $TOK"
CT="Content-Type: application/json"

echo "== fix roles-scope 'realm roles' mapper: add ID-token + userinfo claims =="
curl -ksS "$BASE/admin/realms/$REALM/client-scopes?search=roles" -H "$AUTH" > /tmp/scopes.json
SCOPE_ID="$(python3 -c 'import json;print([s["id"] for s in json.load(open("/tmp/scopes.json")) if s["name"]=="roles"][0])')"
MAPPER_ID="$(curl -ksS "$BASE/admin/realms/$REALM/client-scopes/$SCOPE_ID/protocol-mappers/models" -H "$AUTH" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(next(m["id"] for m in d if m.get("protocolMapper")=="oidc-usermodel-realm-role-mapper"))
')"
echo "  scope=$SCOPE_ID mapper=$MAPPER_ID"
curl -ksS -X PUT "$BASE/admin/realms/$REALM/client-scopes/$SCOPE_ID/protocol-mappers/models/$MAPPER_ID" \
  -H "$AUTH" -H "$CT" -d '{
    "name":"realm roles","protocol":"openid-connect",
    "protocolMapper":"oidc-usermodel-realm-role-mapper",
    "consentRequired":false,
    "config":{
      "user.attribute":"foo","introspection.token.claim":"true",
      "access.token.claim":"true","id.token.claim":"true","userinfo.token.claim":"true",
      "claim.name":"realm_access.roles","jsonType.label":"String","multivalued":"true"
    }
  }'
echo "mapper updated"

echo
echo "== ensure client redirect/web origins =="
CLIENT_UUID="$(curl -ksS "$BASE/admin/realms/$REALM/clients?clientId=$CLIENT_ID" -H "$AUTH" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
curl -ksS -X PUT "$BASE/admin/realms/$REALM/clients/$CLIENT_UUID" -H "$AUTH" -H "$CT" -d '{
  "clientId":"'$CLIENT_ID'","enabled":true,"protocol":"openid-connect",
  "publicClient":false,"standardFlowEnabled":true,"directAccessGrantsEnabled":true,
  "redirectUris":["'$GRAFANA_URL'/login/generic_oauth"],
  "webOrigins":["'$GRAFANA_URL'"],
  "secret":"'$CLIENT_SECRET'",
  "attributes":{"post.logout.redirect.uris":"+"}
}'
echo "client updated ($CLIENT_UUID)"

echo
echo "== create user esmacan (grafana-admin) =="
EXIST="$(curl -ksS "$BASE/admin/realms/$REALM/users?username=esmacan&exact=true" -H "$AUTH" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if d else "")')"
if [ -n "$EXIST" ]; then
  echo "esmacan exists ($EXIST)"
  ESM_UID="$EXIST"
else
  ESM_PASS="$(python3 -c 'import secrets,string;print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(20)))')"
  curl -ksS -X POST "$BASE/admin/realms/$REALM/users" -H "$AUTH" -H "$CT" -d '{
    "username":"esmacan","enabled":true,"emailVerified":true,
    "email":"esmacan@otech.om","firstName":"Esmacan","lastName":"(grafana admin)",
    "credentials":[{"type":"password","value":"'$ESM_PASS'","temporary":false}]
  }' -o /dev/null
  echo "$ESM_PASS" > /tmp/esmacan_pw
  ESM_UID="$(curl -ksS "$BASE/admin/realms/$REALM/users?username=esmacan&exact=true" -H "$AUTH" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
  echo "esmacan created ($ESM_UID), pw -> /tmp/esmacan_pw"
fi

echo
echo "== assign grafana-admin realm role =="
ADMIN_ROLE_ID="$(curl -ksS "$BASE/admin/realms/$REALM/roles/grafana-admin" -H "$AUTH" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
curl -ksS -X POST "$BASE/admin/realms/$REALM/users/$ESM_UID/role-mappings/realm" \
  -H "$AUTH" -H "$CT" -d '[{"id":"'$ADMIN_ROLE_ID'","name":"grafana-admin"}]' -o /dev/null
echo "assigned"

echo
echo "== ID-token claim check (password grant) =="
ESM_PASS="$(cat /tmp/esmacan_pw)"
curl -ksS -X POST "$BASE/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode "client_id=$CLIENT_ID" --data-urlencode "client_secret=$CLIENT_SECRET" \
  --data-urlencode "grant_type=password" --data-urlencode "username=esmacan" \
  --data-urlencode "password=$ESM_PASS" --data-urlencode "scope=openid profile email" > /tmp/esmacan_token.json
python3 - <<'PY'
import json,base64
d=json.load(open("/tmp/esmacan_token.json"))
def dec(tok):
    p=tok.split(".")[1]; p+="="*((4-len(p)%4)%4)
    return json.loads(base64.urlsafe_b64decode(p))
idtok=dec(d["id_token"])
print("id_token.email:", idtok.get("email"))
print("id_token.realm_access.roles:", json.dumps(idtok.get("realm_access",{}).get("roles")))
rak=idtok.get("realm_access",{}).get("roles") or []
print("OK" if "grafana-admin" in rak else "!!! realm_access.roles missing from ID token !!!")
PY

echo
echo "client secret check: $(curl -ksS "$BASE/admin/realms/$REALM/clients/$CLIENT_UUID/client-secret" -H "$AUTH" | python3 -c "import sys,json;print('OK' if json.load(sys.stdin)['value']=='$CLIENT_SECRET' else 'MISMATCH')")"
echo "realm discovery code: $(curl -ksS -o /dev/null -w '%{http_code}' "$BASE/realms/$REALM/.well-known/openid-configuration")"
echo "DONE"