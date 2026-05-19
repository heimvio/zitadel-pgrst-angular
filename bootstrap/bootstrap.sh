#!/bin/sh
# =============================================================================
# Idempotenter Zitadel-Bootstrap für die Demo.
#  - 2 Orgs (Firma A / Firma B), je 1 staff- + 1 customer-User
#  - 1 Projekt + OIDC-SPA-App (PKCE, Access-Token = JWT)
#  - Seed auth.organizations/auth.users/auth.user_roles + Beispiel-Produkte
#  - JWKS für PostgREST + Login-Config schreiben
# Idempotenz: persistentes /shared-Volume. Ist bootstrap.done vorhanden,
# wird nur die JWKS aktualisiert (Key-Rotation) und beendet.
# =============================================================================
set -eu

API="${ZITADEL_API}"
SHARED=/shared
mkdir -p "$SHARED"

# Zitadel löst die Instanz per Host-Header auf. Intern erreichen wir Zitadel
# über den Service-Namen, müssen aber den ExternalDomain-Host vorgeben.
ZHOST="Host: localhost"

apk add --no-cache curl jq postgresql16-client >/dev/null

echo "bootstrap: warte auf Zitadel-API ..."
i=0
until curl -sf -H "$ZHOST" "$API/oauth/v2/keys" >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 120 ] && { echo "Zitadel-API nicht erreichbar"; exit 1; }
  sleep 2
done

# JWKS immer aktualisieren (auch bei Re-Run / Key-Rotation)
curl -sf -H "$ZHOST" "$API/oauth/v2/keys" -o "$SHARED/jwks.json"
echo "bootstrap: JWKS geschrieben."

if [ -f "$SHARED/bootstrap.done" ]; then
  echo "bootstrap: bereits initialisiert (bootstrap.done) — nur JWKS erneuert."
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

echo "bootstrap: lege Organisationen an ..."
ORGA=$(api POST /v2/organizations '{"name":"Firma A"}' | jq -r '.organizationId')
ORGB=$(api POST /v2/organizations '{"name":"Firma B"}' | jq -r '.organizationId')
[ -n "$ORGA" ] && [ -n "$ORGB" ] || { echo "Org-Anlage fehlgeschlagen"; exit 1; }
echo "  Firma A=$ORGA  Firma B=$ORGB"

mk_user() { # orgid given family email  -> echoes userId
  body=$(jq -nc --arg g "$2" --arg f "$3" --arg e "$4" --arg p "$DEMO_USER_PASSWORD" \
    '{profile:{givenName:$g,familyName:$f},email:{email:$e,isVerified:true},password:{password:$p,changeRequired:false}}')
  api POST /v2/users/human "$body" "x-zitadel-orgid: $1" | jq -r '.userId'
}

echo "bootstrap: lege Benutzer an ..."
ALICE=$(mk_user "$ORGA" Alice Staff    alice@a.demo)
BOB=$(  mk_user "$ORGA" Bob   Customer bob@a.demo)
CAROL=$(mk_user "$ORGB" Carol Staff    carol@b.demo)
DAVE=$( mk_user "$ORGB" Dave  Customer dave@b.demo)
echo "  alice=$ALICE bob=$BOB carol=$CAROL dave=$DAVE"

echo "bootstrap: Projekt + OIDC-App (in Firma A) ..."
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
[ -n "$CLIENTID" ] && [ "$CLIENTID" != null ] || { echo "App-Anlage fehlgeschlagen"; exit 1; }
echo "  clientId=$CLIENTID"

echo "bootstrap: Seed in Postgres (auth.* + Produkte) ..."
psql -v ON_ERROR_STOP=1 <<SQL
INSERT INTO auth.organizations (zitadel_org_id, name) VALUES
  ('$ORGA','Firma A'), ('$ORGB','Firma B')
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

INSERT INTO public.products (org_id, name, price)
  SELECT (SELECT id FROM auth.organizations WHERE zitadel_org_id='$ORGA'), n, p
  FROM (VALUES ('A-Widget',9.99),('A-Gadget',19.50),('A-Doohickey',4.25)) v(n,p);
INSERT INTO public.products (org_id, name, price)
  SELECT (SELECT id FROM auth.organizations WHERE zitadel_org_id='$ORGB'), n, p
  FROM (VALUES ('B-Sprocket',12.00),('B-Cog',7.75)) v(n,p);
SQL

echo "bootstrap: Runtime-Config (config.json) für die Angular-App schreiben ..."
cat > "$SHARED/config.json" <<EOF
{
  "postgrest": { "url": "http://localhost:${POSTGREST_PORT:-3001}" },
  "oidc": {
    "issuer": "${ZITADEL_ISSUER}",
    "clientId": "${CLIENTID}",
    "redirectPath": "/callback",
    "scope": "openid profile email urn:zitadel:iam:user:resourceowner"
  },
  "demo": {
    "password": "${DEMO_USER_PASSWORD}",
    "users": ["alice@a.demo (Firma A·staff)", "bob@a.demo (Firma A·customer)",
              "carol@b.demo (Firma B·staff)", "dave@b.demo (Firma B·customer)"]
  }
}
EOF

touch "$SHARED/bootstrap.done"
echo "bootstrap: fertig."
