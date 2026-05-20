#!/bin/sh
# Headless equivalent of the DoD: real Zitadel JWT -> PostgREST JWKS verify
# -> JIT (public.ensure_principal) -> RLS org isolation + role gating.
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

ORGA=$(org_id "Company A"); ORGB=$(org_id "Company B")
set -- $(mk_machine "$ORGA" "svca$(date +%s)"); CA=$1;SA=$2;UA=$3
set -- $(mk_machine "$ORGB" "svcb$(date +%s)"); CB=$1;SB=$2;UB=$3
TA=$(token "$CA" "$SA"); TB=$(token "$CB" "$SB")

echo "### Step 0 — claims in the real access token (svc-a)"
echo "$TA" | cut -d. -f2 | tr '_-' '/+' | (cat;echo '==') | base64 -d 2>/dev/null \
  | jq '{aud,iss,sub,org:."urn:zitadel:iam:user:resourceowner:id"}'

POST(){ curl -s -X POST -H "Authorization: Bearer $1" -H "$J" "$PGRST$2" ${3:+-d "$3"}; }
echo "### JIT: POST /rpc/ensure_principal (svc-a, writable)"
POST "$TA" /rpc/ensure_principal; echo
POST "$TB" /rpc/ensure_principal >/dev/null

echo "### whoami (svc-a) — roles still empty => default-deny"
GB "$TA" /rpc/whoami; echo
echo "GET /products svc-a (no role): HTTP $(G "$TA" /products)  Body: $(GB "$TA" /products)"

echo "### Assign roles in the DB: svc-a=staff (Company A), svc-b=customer (Company B)"
$PSQL -c "INSERT INTO auth.user_roles(user_id,role) SELECT id,'staff' FROM auth.users WHERE zitadel_sub='$UA' ON CONFLICT DO NOTHING;"
$PSQL -c "INSERT INTO auth.user_roles(user_id,role) SELECT id,'customer' FROM auth.users WHERE zitadel_sub='$UB' ON CONFLICT DO NOTHING;"

echo "### Org isolation"
echo "svc-a /products: $(GB "$TA" '/products?select=name,price&order=name')"
echo "svc-b /products: $(GB "$TB" '/products?select=name,price&order=name')"

echo "### Role gating (INSERT)"
echo "svc-a (staff) POST /products: HTTP $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TA" -H "$J" -X POST "$PGRST/products" -d '{"name":"A-New","price":1.23}')  (expected 201)"
echo "svc-b (customer) POST /products: HTTP $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TB" -H "$J" -X POST "$PGRST/products" -d '{"name":"B-Hack","price":9.99}')  (expected 401/403/4xx)"
echo "svc-a after insert: $(GB "$TA" '/products?select=name&order=name')"

echo
echo "### Provisioning RPCs — gating + org scope"
# svc-a is currently only 'staff'. provision_user must refuse.
PR_NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TA" -H "$J" \
  -X POST "$PGRST/rpc/provision_user" \
  -d '{"p_zitadel_sub":"verify-fake-1","p_email":"reject@a.demo","p_roles":["customer"]}')
echo "svc-a (no org_owner) provision_user: HTTP $PR_NOAUTH  (expected 403)"

# Promote svc-a to org_owner and retry.
$PSQL -c "INSERT INTO auth.user_roles(user_id,role) SELECT id,'org_owner' FROM auth.users WHERE zitadel_sub='$UA' ON CONFLICT DO NOTHING;"
NEW_SUB="verify-fake-$(date +%s)"
PR_OK=$(curl -s -H "Authorization: Bearer $TA" -H "$J" \
  -X POST "$PGRST/rpc/provision_user" \
  -d "$(jq -nc --arg s "$NEW_SUB" '{p_zitadel_sub:$s,p_email:"verified@a.demo",p_roles:["customer"]}')")
echo "svc-a (org_owner) provision_user response: $PR_OK"

echo "list_org_users (svc-a):"
curl -s -H "Authorization: Bearer $TA" -H "$J" -X POST "$PGRST/rpc/list_org_users" -d '{}' | jq

# Cross-org guard: svc-a tries to remove svc-b (Company B).
PR_CROSS=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TA" -H "$J" \
  -X POST "$PGRST/rpc/remove_user" \
  -d "$(jq -nc --arg id "$UB" '{p_user_id:(null)}')")
# We need svc-b's DB UUID (not Zitadel sub) for remove_user; look it up:
UB_DB=$($PSQL -c "SELECT id FROM auth.users WHERE zitadel_sub='$UB'" | head -n1)
PR_CROSS=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TA" -H "$J" \
  -X POST "$PGRST/rpc/remove_user" \
  -d "$(jq -nc --arg id "$UB_DB" '{p_user_id:$id}')")
echo "svc-a tries to remove svc-b (cross-org): HTTP $PR_CROSS  (expected 4xx)"
