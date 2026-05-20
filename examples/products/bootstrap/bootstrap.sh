#!/bin/sh
# =============================================================================
# Idempotent Zitadel bootstrap for the demo.
#  - 2 orgs (Company A / Company B), each with 1 staff + 1 customer user
#  - 1 project + OIDC SPA app (PKCE, access token = JWT)
#  - Seed auth.organizations/auth.users/auth.user_roles + example products
#  - Write JWKS for PostgREST + the app's runtime config.json
# Idempotency: persistent /shared volume. If bootstrap.done exists, only the
# JWKS is refreshed (key rotation) and the script exits.
# =============================================================================
set -eu

API="${ZITADEL_API}"
SHARED=/shared
mkdir -p "$SHARED"

# Zitadel resolves the instance via the Host header. Internally we reach
# Zitadel by service name but must present the ExternalDomain host.
ZHOST="Host: localhost"

apk add --no-cache curl jq postgresql16-client >/dev/null

echo "bootstrap: waiting for the Zitadel API ..."
i=0
until curl -sf -H "$ZHOST" "$API/oauth/v2/keys" >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 120 ] && { echo "Zitadel API not reachable"; exit 1; }
  sleep 2
done

# Always refresh the JWKS (also on re-run / key rotation)
curl -sf -H "$ZHOST" "$API/oauth/v2/keys" -o "$SHARED/jwks.json"
echo "bootstrap: JWKS written."

# Force the built-in v1 login UI: the separate LoginV2 app (/ui/v2/login) is
# not part of this stack and would 404. Idempotent; also fixes an instance
# created before this setting existed. Runs even on the JWKS-only re-run path.
curl -s -H "$ZHOST" \
  -H "Authorization: Bearer $(cat /bootstrap/admin-client.pat)" \
  -H "Content-Type: application/json" \
  -X PUT "$API/v2/features/instance" \
  -d '{"loginV2":{"required":false}}' >/dev/null \
  && echo "bootstrap: LoginV2 disabled (using v1 /ui/login)." \
  || echo "bootstrap: WARN could not set loginV2 feature (continuing)."

if [ -f "$SHARED/bootstrap.done" ]; then
  echo "bootstrap: already initialised (bootstrap.done) — only refreshed JWKS."
  exit 0
fi

PAT="$(cat /bootstrap/admin-client.pat)"
AUTH="Authorization: Bearer $PAT"
JSON="Content-Type: application/json"

api() { # METHOD PATH [BODY] [EXTRA_HEADER]
  m="$1"; p="$2"; b="${3:-}"; h="${4:-}"
  if [ -n "$b" ]; then
    curl -sf -X "$m" "$API$p" -H "$ZHOST" -H "$AUTH" -H "$JSON" ${h:+-H "$h"} -d "$b"
  else
    curl -sf -X "$m" "$API$p" -H "$ZHOST" -H "$AUTH" ${h:+-H "$h"}
  fi
}

echo "bootstrap: creating organizations ..."
ORGA=$(api POST /v2/organizations '{"name":"Company A"}' | jq -r '.organizationId')
ORGB=$(api POST /v2/organizations '{"name":"Company B"}' | jq -r '.organizationId')
[ -n "$ORGA" ] && [ -n "$ORGB" ] || { echo "org creation failed"; exit 1; }
echo "  Company A=$ORGA  Company B=$ORGB"

mk_user() { # orgid given family email  -> echoes userId
  body=$(jq -nc --arg g "$2" --arg f "$3" --arg e "$4" --arg p "$DEMO_USER_PASSWORD" \
    '{profile:{givenName:$g,familyName:$f},email:{email:$e,isVerified:true},password:{password:$p,changeRequired:false}}')
  api POST /v2/users/human "$body" "x-zitadel-orgid: $1" | jq -r '.userId'
}

echo "bootstrap: creating users ..."
ALICE=$(mk_user "$ORGA" Alice Staff    alice@a.demo)
BOB=$(  mk_user "$ORGA" Bob   Customer bob@a.demo)
CAROL=$(mk_user "$ORGB" Carol Staff    carol@b.demo)
DAVE=$( mk_user "$ORGB" Dave  Customer dave@b.demo)
echo "  alice=$ALICE bob=$BOB carol=$CAROL dave=$DAVE"

echo "bootstrap: granting Zitadel ORG_OWNER membership to alice + carol ..."
add_org_owner() { # orgid userid
  api POST /management/v1/orgs/me/members \
    "$(jq -nc --arg u "$2" '{userId:$u, roles:["ORG_OWNER"]}')" \
    "x-zitadel-orgid: $1" >/dev/null \
    && echo "  ✓ $2 is ORG_OWNER in $1" \
    || echo "  · already ORG_OWNER (or other 4xx) for $2 in $1"
}
add_org_owner "$ORGA" "$ALICE"
add_org_owner "$ORGB" "$CAROL"

echo "bootstrap: project + OIDC app (in Company A) ..."
PROJ=$(api POST /management/v1/projects '{"name":"demo"}' "x-zitadel-orgid: $ORGA" | jq -r '.id')
APPBODY=$(jq -nc --arg r "$LOGIN_ORIGIN/" --arg cb "$LOGIN_ORIGIN/callback" \
  '{name:"spa",
    redirectUris:[$r,$cb],
    postLogoutRedirectUris:[$r],
    responseTypes:["OIDC_RESPONSE_TYPE_CODE"],
    grantTypes:["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"],
    appType:"OIDC_APP_TYPE_USER_AGENT",
    authMethodType:"OIDC_AUTH_METHOD_TYPE_NONE",
    devMode:true,
    accessTokenType:"OIDC_TOKEN_TYPE_JWT",
    accessTokenRoleAssertion:true,
    idTokenRoleAssertion:true,
    idTokenUserinfoAssertion:true}')
CLIENTID=$(api POST "/management/v1/projects/$PROJ/apps/oidc" "$APPBODY" "x-zitadel-orgid: $ORGA" | jq -r '.clientId')
[ -n "$CLIENTID" ] && [ "$CLIENTID" != null ] || { echo "app creation failed"; exit 1; }
echo "  clientId=$CLIENTID"

echo "bootstrap: seeding Postgres (auth.* + products) ..."
psql -v ON_ERROR_STOP=1 <<SQL
INSERT INTO auth.organizations (zitadel_org_id, name) VALUES
  ('$ORGA','Company A'), ('$ORGB','Company B')
ON CONFLICT (zitadel_org_id) DO NOTHING;

INSERT INTO auth.users (zitadel_sub, org_id, email) VALUES
  ('$ALICE',(SELECT id FROM auth.organizations WHERE zitadel_org_id='$ORGA'),'alice@a.demo'),
  ('$BOB',  (SELECT id FROM auth.organizations WHERE zitadel_org_id='$ORGA'),'bob@a.demo'),
  ('$CAROL',(SELECT id FROM auth.organizations WHERE zitadel_org_id='$ORGB'),'carol@b.demo'),
  ('$DAVE', (SELECT id FROM auth.organizations WHERE zitadel_org_id='$ORGB'),'dave@b.demo')
ON CONFLICT (zitadel_sub) DO NOTHING;

INSERT INTO auth.user_roles (user_id, role)
  SELECT id,'staff'    FROM auth.users WHERE zitadel_sub IN ('$ALICE','$CAROL')
ON CONFLICT DO NOTHING;
INSERT INTO auth.user_roles (user_id, role)
  SELECT id,'customer' FROM auth.users WHERE zitadel_sub IN ('$BOB','$DAVE')
ON CONFLICT DO NOTHING;
-- org_owner for alice + carol so each Company has an admin who can
-- exercise the provisioning UI (/admin/users) in the demo + e2e tests.
INSERT INTO auth.user_roles (user_id, role)
  SELECT id,'org_owner' FROM auth.users WHERE zitadel_sub IN ('$ALICE','$CAROL')
ON CONFLICT DO NOTHING;

INSERT INTO public.products (org_id, name, price)
  SELECT (SELECT id FROM auth.organizations WHERE zitadel_org_id='$ORGA'), n, p
  FROM (VALUES ('A-Widget',9.99),('A-Gadget',19.50),('A-Doohickey',4.25)) v(n,p);
INSERT INTO public.products (org_id, name, price)
  SELECT (SELECT id FROM auth.organizations WHERE zitadel_org_id='$ORGB'), n, p
  FROM (VALUES ('B-Sprocket',12.00),('B-Cog',7.75)) v(n,p);
SQL

echo "bootstrap: writing runtime config (config.json) for the Angular app ..."
cat > "$SHARED/config.json" <<EOF
{
  "postgrest": { "url": "http://localhost:${POSTGREST_PORT:-3001}" },
  "oidc": {
    "issuer": "${ZITADEL_ISSUER}",
    "clientId": "${CLIENTID}",
    "redirectPath": "/callback",
    "scope": "openid profile email urn:zitadel:iam:user:resourceowner urn:zitadel:iam:org:project:id:zitadel:aud"
  },
  "demo": {
    "password": "${DEMO_USER_PASSWORD}",
    "users": ["alice@a.demo (Company A staff + org_owner)", "bob@a.demo (Company A customer)",
              "carol@b.demo (Company B staff + org_owner)", "dave@b.demo (Company B customer)"]
  }
}
EOF

touch "$SHARED/bootstrap.done"
echo "bootstrap: done."
