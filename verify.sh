#!/bin/sh
# Headless-Äquivalent des DoD: echtes Zitadel-JWT -> PostgREST JWKS-Verify
# -> JIT (public.ensure_principal) -> RLS Org-Isolation + Rollen-Gating.
set -eu
API=http://zitadel:8080
PGRST=http://postgrest:3000
ZH="Host: localhost"
apk add --no-cache curl jq postgresql16-client >/dev/null
export PGPASSWORD=postgres
PSQL="psql -tA -h postgres -U postgres -d appdb"
PAT="$(cat /bootstrap/admin-client.pat)"
A="Authorization: Bearer $PAT"; J="Content-Type: application/json"

org_id() {
  curl -sf -H "$ZH" -H "$A" -H "$J" -X POST "$API/v2/organizations/_search" \
    -d "$(jq -nc --arg n "$1" '{queries:[{nameQuery:{name:$n,method:"TEXT_QUERY_METHOD_EQUALS"}}]}')" \
    | jq -r '.result[0].id'
}
mk_machine() {
  uid=$(curl -sf -H "$ZH" -H "$A" -H "$J" -H "x-zitadel-orgid: $1" \
        -X POST "$API/management/v1/users/machine" \
        -d "$(jq -nc --arg u "$2" '{userName:$u,name:$u,accessTokenType:"ACCESS_TOKEN_TYPE_JWT"}')" | jq -r '.userId')
  sec=$(curl -sf -H "$ZH" -H "$A" -H "$J" -H "x-zitadel-orgid: $1" \
        -X PUT "$API/management/v1/users/$uid/secret" -d '{}')
  echo "$(echo "$sec"|jq -r .clientId) $(echo "$sec"|jq -r .clientSecret) $uid"
}
token() {
  curl -sf -H "$ZH" -u "$1:$2" -X POST "$API/oauth/v2/token" \
    -d 'grant_type=client_credentials' \
    --data-urlencode 'scope=openid profile urn:zitadel:iam:user:resourceowner' | jq -r .access_token
}
G(){ curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" "$PGRST$2"; }
GB(){ curl -s -H "Authorization: Bearer $1" "$PGRST$2"; }

ORGA=$(org_id "Firma A"); ORGB=$(org_id "Firma B")
set -- $(mk_machine "$ORGA" "svca$(date +%s)"); CA=$1;SA=$2;UA=$3
set -- $(mk_machine "$ORGB" "svcb$(date +%s)"); CB=$1;SB=$2;UB=$3
TA=$(token "$CA" "$SA"); TB=$(token "$CB" "$SB")

echo "### Schritt 0 — Claims im echten Access-Token (svc-a)"
echo "$TA" | cut -d. -f2 | tr '_-' '/+' | (cat;echo '==') | base64 -d 2>/dev/null \
  | jq '{aud,iss,sub,org:."urn:zitadel:iam:user:resourceowner:id"}'

POST(){ curl -s -X POST -H "Authorization: Bearer $1" -H "$J" "$PGRST$2" ${3:+-d "$3"}; }
echo "### JIT: POST /rpc/ensure_principal (svc-a, schreibbar)"
POST "$TA" /rpc/ensure_principal; echo
POST "$TB" /rpc/ensure_principal >/dev/null

echo "### whoami (svc-a) — roles noch leer => Default-Deny"
GB "$TA" /rpc/whoami; echo
echo "GET /products svc-a (ohne Rolle): HTTP $(G "$TA" /products)  Body: $(GB "$TA" /products)"

echo "### Rollen DB-seitig vergeben: svc-a=staff (Firma A), svc-b=customer (Firma B)"
$PSQL -c "INSERT INTO auth.user_roles(user_id,role) SELECT id,'staff' FROM auth.users WHERE zitadel_sub='$UA' ON CONFLICT DO NOTHING;"
$PSQL -c "INSERT INTO auth.user_roles(user_id,role) SELECT id,'customer' FROM auth.users WHERE zitadel_sub='$UB' ON CONFLICT DO NOTHING;"

echo "### Org-Isolation"
echo "svc-a /products: $(GB "$TA" '/products?select=name,price&order=name')"
echo "svc-b /products: $(GB "$TB" '/products?select=name,price&order=name')"

echo "### Rollen-Gating (INSERT)"
echo "svc-a (staff) POST /products: HTTP $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TA" -H "$J" -X POST "$PGRST/products" -d '{"name":"A-New","price":1.23}')  (erwartet 201)"
echo "svc-b (customer) POST /products: HTTP $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TB" -H "$J" -X POST "$PGRST/products" -d '{"name":"B-Hack","price":9.99}')  (erwartet 401/403/4xx)"
echo "svc-a sieht nach Insert: $(GB "$TA" '/products?select=name&order=name')"
