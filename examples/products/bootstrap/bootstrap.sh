#!/bin/sh
# =============================================================================
# Example (products) bootstrap — runs AFTER bootstrap/bootstrap.sh.
# Adds the demo-specific seed on top of the IAM bootstrap:
#   * 2nd Zitadel org (Company B) + Bob / Carol / Dave demo users
#   * auth.* mirror + role rows (staff / customer / org_owner) for those users
#   * public.products rows for both orgs
#   * SPA runtime config.json (postgrest URL, OIDC issuer/clientId, demo block)
#
# Inputs:
#   /shared/iam.env            (written by the base bootstrap)
#   /config/config.json        (reads only the .app section)
# =============================================================================
set -eu

CONFIG="${BOOTSTRAP_CONFIG:-/config/config.json}"
SHARED="${BOOTSTRAP_SHARED:-/shared}"

[ -f "$SHARED/iam.env" ] || { echo "example-bootstrap: $SHARED/iam.env missing — run base bootstrap first"; exit 1; }
[ -f "$CONFIG" ]         || { echo "example-bootstrap: $CONFIG missing"; exit 1; }

# shellcheck disable=SC1090
. "$SHARED/iam.env"

apk add --no-cache curl jq postgresql16-client >/dev/null

API="${ZITADEL_API}"
ZHOST="Host: localhost"
PAT_FILE="${BOOTSTRAP_PAT_FILE:-/bootstrap/admin-client.pat}"
[ -f "$PAT_FILE" ] || { echo "example-bootstrap: missing $PAT_FILE"; exit 1; }
PAT="$(cat "$PAT_FILE")"

: "${PGHOST:?PGHOST}"; : "${PGUSER:?PGUSER}"; : "${PGPASSWORD:?PGPASSWORD}"
export PGHOST PGUSER PGPASSWORD
export PGDATABASE="${PGDATABASE:-$IAM_DB_NAME}"

if [ -f "$SHARED/example-bootstrap.done" ]; then
  echo "example-bootstrap: already initialised — nothing to do."
  exit 0
fi

AUTH_H="Authorization: Bearer $PAT"
JSON_H="Content-Type: application/json"
api() { # METHOD PATH [BODY] [EXTRA_HEADER]
  m="$1"; p="$2"; b="${3:-}"; h="${4:-}"
  if [ -n "$b" ]; then
    curl -sf -X "$m" "$API$p" -H "$ZHOST" -H "$AUTH_H" -H "$JSON_H" ${h:+-H "$h"} -d "$b"
  else
    curl -sf -X "$m" "$API$p" -H "$ZHOST" -H "$AUTH_H" ${h:+-H "$h"}
  fi
}

DEMO_PW=$(jq -r '.app.demoPassword // "Demo1!Pass"' "$CONFIG")
SECOND_ORG_NAME=$(jq -r '.app.secondOrg.name // "Company B"' "$CONFIG")
IAM_OWNER_EXTRA_ROLES_JSON=$(jq -c '.app.iamOwnerExtraRoles // []' "$CONFIG")

# --------------------------------------------------------- 2nd Zitadel org ---
echo "example-bootstrap: creating second organization '$SECOND_ORG_NAME' ..."
ORG2_ID=$(api POST /v2/organizations \
  "$(jq -nc --arg n "$SECOND_ORG_NAME" '{name:$n}')" | jq -r '.organizationId')
[ -n "$ORG2_ID" ] && [ "$ORG2_ID" != "null" ] || { echo "second org creation failed"; exit 1; }
echo "  ORG2_ID=$ORG2_ID"

# --------------------------------------------- Demo users (in either org) ---
mk_user() { # zitadel_org_id given family email -> userId
  body=$(jq -nc --arg g "$2" --arg f "$3" --arg e "$4" --arg p "$DEMO_PW" \
    '{profile:{givenName:$g,familyName:$f},
      email:{email:$e,isVerified:true},
      password:{password:$p,changeRequired:false}}')
  api POST /v2/users/human "$body" "x-zitadel-orgid: $1" | jq -r '.userId'
}
add_org_owner() { # zitadel_org_id user_id
  api POST /management/v1/orgs/me/members \
    "$(jq -nc --arg u "$2" '{userId:$u, roles:["ORG_OWNER"]}')" \
    "x-zitadel-orgid: $1" >/dev/null \
    && echo "  ✓ $2 is ORG_OWNER in $1" \
    || echo "  · already ORG_OWNER (or other 4xx) for $2 in $1"
}

USERS_JSON=$(jq -c '.app.demoUsers // []' "$CONFIG")

USER_ROWS_SQL=""
ROLE_ROWS_SQL=""
USER_DESCRIPTIONS=""

i=0
while :; do
  u=$(printf '%s' "$USERS_JSON" | jq -c ".[$i] // empty")
  [ -z "$u" ] && break

  GIVEN=$(printf '%s' "$u" | jq -r '.given')
  FAMILY=$(printf '%s' "$u" | jq -r '.family')
  EMAIL=$(printf '%s' "$u" | jq -r '.email')
  ORG_TAG=$(printf '%s' "$u" | jq -r '.org')   # "iam" | "second"

  case "$ORG_TAG" in
    iam)    Z_ORG_ID="$IAM_ORG_ID";  ORG_HUMAN="$IAM_ORG_NAME" ;;
    second) Z_ORG_ID="$ORG2_ID";     ORG_HUMAN="$SECOND_ORG_NAME" ;;
    *) echo "  unknown org tag '$ORG_TAG' for $EMAIL"; exit 1 ;;
  esac

  echo "example-bootstrap: creating user $EMAIL in $ORG_HUMAN ..."
  USER_ID=$(mk_user "$Z_ORG_ID" "$GIVEN" "$FAMILY" "$EMAIL")
  [ -n "$USER_ID" ] && [ "$USER_ID" != "null" ] || { echo "user creation failed: $EMAIL"; exit 1; }

  USER_ROWS_SQL="$USER_ROWS_SQL
  ('$USER_ID', (SELECT id FROM auth.organizations WHERE zitadel_org_id = '$Z_ORG_ID'), '$EMAIL'),"

  ROLES_JSON=$(printf '%s' "$u" | jq -c '.roles // []')
  rj=0
  while :; do
    r=$(printf '%s' "$ROLES_JSON" | jq -r ".[$rj] // empty")
    [ -z "$r" ] && break
    if [ "$r" = "org_owner" ]; then
      add_org_owner "$Z_ORG_ID" "$USER_ID"
    fi
    ROLE_ROWS_SQL="$ROLE_ROWS_SQL
INSERT INTO auth.user_roles (user_id, role)
  SELECT id, '$r' FROM auth.users WHERE zitadel_sub = '$USER_ID'
  ON CONFLICT DO NOTHING;"
    rj=$((rj+1))
  done

  # Human-readable demo blurb
  R_PRETTY=$(printf '%s' "$ROLES_JSON" | jq -r 'join(" + ")')
  USER_DESCRIPTIONS="$USER_DESCRIPTIONS\n  \"$EMAIL ($ORG_HUMAN $R_PRETTY)\","

  i=$((i+1))
done

# Strip the final trailing comma (parameter expansion = only the last char).
USER_ROWS_SQL="${USER_ROWS_SQL%,}"

# Add extra app-level roles to the IAM owner (e.g. staff for the products RLS).
ki=0
while :; do
  er=$(printf '%s' "$IAM_OWNER_EXTRA_ROLES_JSON" | jq -r ".[$ki] // empty")
  [ -z "$er" ] && break
  ROLE_ROWS_SQL="$ROLE_ROWS_SQL
INSERT INTO auth.user_roles (user_id, role)
  SELECT id, '$er' FROM auth.users WHERE zitadel_sub = '$IAM_OWNER_USER_ID'
  ON CONFLICT DO NOTHING;"
  ki=$((ki+1))
done

# ----------------------------------------- Products seed (per org_tag map) ---
PRODUCTS_IAM_JSON=$(jq -c '.app.products.iam // []' "$CONFIG")
PRODUCTS_SECOND_JSON=$(jq -c '.app.products.second // []' "$CONFIG")

products_sql() { # JSON_ARRAY_OF_[name,price] ZITADEL_ORG_ID
  arr="$1"; zoid="$2"
  rows=""
  pi=0
  while :; do
    pn=$(printf '%s' "$arr" | jq -r ".[$pi][0] // empty")
    pp=$(printf '%s' "$arr" | jq -r ".[$pi][1] // empty")
    [ -z "$pn" ] && break
    rows="$rows ('$pn', $pp),"
    pi=$((pi+1))
  done
  [ -z "$rows" ] && return 0
  rows="${rows%,}"
  printf "INSERT INTO public.products (org_id, name, price)\n  SELECT (SELECT id FROM auth.organizations WHERE zitadel_org_id = '%s'), n, p\n  FROM (VALUES %s) v(n,p);\n" "$zoid" "$rows"
}

PRODUCTS_SQL=$(products_sql "$PRODUCTS_IAM_JSON" "$IAM_ORG_ID"; products_sql "$PRODUCTS_SECOND_JSON" "$ORG2_ID")

# ---------------------------------------------------------- DB mirror seed ---
echo "example-bootstrap: seeding auth.* + products ..."
psql -v ON_ERROR_STOP=1 <<SQL
INSERT INTO auth.organizations (zitadel_org_id, name) VALUES
  ('$ORG2_ID', '$SECOND_ORG_NAME')
ON CONFLICT (zitadel_org_id) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO auth.users (zitadel_sub, org_id, email) VALUES${USER_ROWS_SQL}
ON CONFLICT (zitadel_sub) DO UPDATE
  SET email = COALESCE(EXCLUDED.email, auth.users.email);

${ROLE_ROWS_SQL}

${PRODUCTS_SQL}
SQL

# ------------------------------------------------- SPA runtime config.json ---
echo "example-bootstrap: writing runtime config.json for the Angular app ..."
USERS_JSON_BLOCK="${USER_DESCRIPTIONS%,}"

# Combine the IAM owner's base role with the demo extra roles for the blurb.
IAM_OWNER_ROLES_PRETTY=$(jq -nr \
  --arg base "$IAM_ORG_ADMIN_ROLE" \
  --argjson extra "$IAM_OWNER_EXTRA_ROLES_JSON" '
  ([$base] + $extra) | unique | join(" + ")')

cat > "$SHARED/config.json" <<EOF
{
  "postgrest": { "url": "http://localhost:${POSTGREST_PORT:-3001}" },
  "oidc": {
    "issuer": "${IAM_ISSUER}",
    "clientId": "${IAM_CLIENT_ID}",
    "redirectPath": "/callback",
    "scope": "openid profile email urn:zitadel:iam:user:resourceowner urn:zitadel:iam:org:project:id:zitadel:aud"
  },
  "demo": {
    "password": "${DEMO_PW}",
    "users": [
      "${IAM_OWNER_EMAIL} (${IAM_ORG_NAME} ${IAM_OWNER_ROLES_PRETTY})",$(printf '%b' "$USERS_JSON_BLOCK")
    ]
  }
}
EOF

touch "$SHARED/example-bootstrap.done"
echo "example-bootstrap: done."
