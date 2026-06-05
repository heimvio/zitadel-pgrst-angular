#!/bin/sh
# =============================================================================
# Base/IAM bootstrap — provisions one tenant from scratch:
#   * Postgres database + auth schema (00/01/02 SQL applied)
#   * Configurable DB role name for the org admin (auth.org_admin_role override)
#   * Zitadel organization + project + OIDC SPA app
#   * First org_owner human user (Zitadel ORG_OWNER + auth.user_roles entry)
#
# Configured ENTIRELY via /config/config.json. Reusable: same script runs in
# the demo docker-compose and in production (proxvex).
#
# Two phases:
#   ALWAYS (every run, makes upgrade possible):
#     - refresh JWKS, disable LoginV2 instance feature
#     - ensure database exists; apply db/*.sql (idempotent) + run migrations
#     - self-assert auth.* permissions
#   ONCE (gated by /shared/iam-bootstrap.done):
#     - create Zitadel org/project/app + first owner
#     - mirror into auth.* and write iam.env + minimal SPA config.json
#
# Outputs for downstream consumers (e.g. example bootstrap, SPA):
#   /shared/iam.env            (IAM_ORG_ID / IAM_CLIENT_ID / IAM_ISSUER / ...)
#   /shared/jwks.json          (always refreshed — key rotation safe)
#   /shared/config.json        (minimal SPA runtime config)
#   /shared/iam-bootstrap.done (sentinel: Zitadel-side setup ran once)
# =============================================================================
set -eu

API="${ZITADEL_API}"
ISSUER="${ZITADEL_ISSUER}"
CONFIG="${BOOTSTRAP_CONFIG:-/config/config.json}"
SQL_DIR="${BOOTSTRAP_SQL_DIR:-/sql/auth}"
SHARED="${BOOTSTRAP_SHARED:-/shared}"
PAT_FILE="${BOOTSTRAP_PAT_FILE:-/bootstrap/admin-client.pat}"

mkdir -p "$SHARED"
# Host-Header muss zur Zitadel-EXTERNALDOMAIN passen, sonst findet Zitadel keine
# Instanz (404). Aus dem Issuer ableiten (Scheme/Pfad/Port strippen). Demo
# http://localhost:8080 -> localhost; Prod https://auth.example -> auth.example.
# Frueher hart "Host: localhost" -> brach in Prod mit 404 / "API not reachable".
ZHOST_DOMAIN="$(printf '%s' "$ISSUER" | sed -e 's#^[a-z][a-z]*://##' -e 's#/.*$##' -e 's#:[0-9][0-9]*$##')"
ZHOST="Host: ${ZHOST_DOMAIN:-localhost}"

# curl/jq/psql sicherstellen. In schlanken Basis-Images nachinstallieren,
# Paketmanager autodetektieren (apk=Alpine, apt-get=Debian). Frueher hart apk
# -> brach auf Debian-Images mit exit 127.
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 \
   || ! command -v psql >/dev/null 2>&1; then
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl jq postgresql16-client >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null \
      && apt-get install -y -qq --no-install-recommends curl jq postgresql-client >/dev/null
  else
    echo "bootstrap: brauche curl/jq/psql, aber weder apk noch apt-get gefunden" >&2
    exit 1
  fi
fi

[ -f "$CONFIG" ] || { echo "iam-bootstrap: missing $CONFIG"; exit 1; }

# ---------------------------------------------------------------- helpers ---
slugify() {
  # lowercase, non-alnum -> _, collapse repeats, trim. Mirrors what a human
  # would type as a DB name; empty input -> empty output.
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//'
}

cfg_or_default() { # JQ_PATH FALLBACK
  v=$(jq -r "$1 // empty" "$CONFIG")
  if [ -z "$v" ] || [ "$v" = "null" ]; then printf '%s' "$2"; else printf '%s' "$v"; fi
}

# Required fields up front (fail fast)
ORG_NAME=$(jq -r '.iam.orgName // empty' "$CONFIG")
[ -n "$ORG_NAME" ] || { echo "iam-bootstrap: .iam.orgName required"; exit 1; }
for f in givenName familyName email password; do
  v=$(jq -r ".iam.orgOwner.$f // empty" "$CONFIG")
  [ -n "$v" ] || { echo "iam-bootstrap: .iam.orgOwner.$f required"; exit 1; }
done

DB_NAME=$(cfg_or_default '.iam.databaseName' "$(slugify "$ORG_NAME")")
PROJ_NAME=$(cfg_or_default '.iam.projectName' "$ORG_NAME")
APP_NAME=$(cfg_or_default '.iam.appName'     "$ORG_NAME")
ORG_ADMIN_ROLE=$(cfg_or_default '.iam.orgAdminRole' 'org_owner')
LOGIN_ORIGIN=$(cfg_or_default '.iam.loginOrigin' 'http://localhost:8089')

OWNER_GIVEN=$(jq -r '.iam.orgOwner.givenName' "$CONFIG")
OWNER_FAMILY=$(jq -r '.iam.orgOwner.familyName' "$CONFIG")
OWNER_EMAIL=$(jq -r '.iam.orgOwner.email' "$CONFIG")
OWNER_PW=$(jq -r '.iam.orgOwner.password' "$CONFIG")

: "${PGHOST:?PGHOST must be set}"
: "${PGUSER:?PGUSER must be set}"
: "${PGPASSWORD:?PGPASSWORD must be set}"
: "${AUTHENTICATOR_PASSWORD:?AUTHENTICATOR_PASSWORD must be set}"
export PGHOST PGUSER PGPASSWORD

# ---------------------------------------------------------------- Zitadel ---
echo "iam-bootstrap: waiting for the Zitadel API ..."
i=0
until curl -sf -H "$ZHOST" "$API/oauth/v2/keys" >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 120 ] && { echo "Zitadel API not reachable"; exit 1; }
  sleep 2
done

# Always refresh the JWKS (also on re-run / key rotation)
curl -sf -H "$ZHOST" "$API/oauth/v2/keys" -o "$SHARED/jwks.json"
echo "iam-bootstrap: JWKS written."

# Force the built-in v1 login UI (idempotent; also runs on the sentinel path)
[ -f "$PAT_FILE" ] || { echo "iam-bootstrap: missing $PAT_FILE"; exit 1; }
PAT="$(cat "$PAT_FILE")"
curl -s -H "$ZHOST" \
  -H "Authorization: Bearer $PAT" \
  -H "Content-Type: application/json" \
  -X PUT "$API/v2/features/instance" \
  -d '{"loginV2":{"required":false}}' >/dev/null \
  && echo "iam-bootstrap: LoginV2 disabled (using v1 /ui/login)." \
  || echo "iam-bootstrap: WARN could not set loginV2 feature (continuing)."

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

# =========================================================================
# Phase 1 — ALWAYS run (idempotent; carries upgrades).
# =========================================================================

# --------------------------------------------------------------- Database ---
echo "iam-bootstrap: ensuring database '$DB_NAME' exists ..."
PGDATABASE=postgres psql -v ON_ERROR_STOP=1 -tAc \
  "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 \
  || PGDATABASE=postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB_NAME\""

export PGDATABASE="$DB_NAME"

# Definition-style SQL: every *.sql under each colon-separated path in
# $SQL_DIR (no subdirs), merged and sorted ALPHABETICALLY by filename.
# Convention: 00_/01_/02_ are core (lib); apps prefix >= 02_ for their own
# (filename uniqueness across paths is the deployer's responsibility — they
# share one sort order).
# All statements must be idempotent (CREATE TABLE IF NOT EXISTS / CREATE OR
# REPLACE FUNCTION / DROP POLICY IF EXISTS + CREATE POLICY ...).
echo "iam-bootstrap: applying definition SQL ..."
collect_sql() { # PATTERN-WITH-COLONS  → stdout: one absolute path per line
  oldifs="$IFS"; IFS=:
  for d in $1; do
    [ -d "$d" ] && find "$d" -maxdepth 1 -type f -name '*.sql'
  done
  IFS="$oldifs"
}
collect_sql "$SQL_DIR" | awk -F/ '{print $NF "\t" $0}' | sort | cut -f2- \
  | while read -r f; do
      echo "  - $(basename "$f")  ($(dirname "$f"))"
      psql -v ON_ERROR_STOP=1 -v authpw="$AUTHENTICATOR_PASSWORD" -f "$f"
    done

# DB role name override (auth.org_admin_role) — only when non-default.
if [ "$ORG_ADMIN_ROLE" != "org_owner" ]; then
  echo "iam-bootstrap: overriding auth.org_admin_role() -> '$ORG_ADMIN_ROLE'"
  psql -v ON_ERROR_STOP=1 -c "
    CREATE OR REPLACE FUNCTION auth.org_admin_role() RETURNS text
      LANGUAGE sql IMMUTABLE PARALLEL SAFE AS \$\$
      SELECT '$ORG_ADMIN_ROLE'::text
    \$\$;
  "
fi

# ---------------------------------------------------------------- Migrations
# Delta-style SQL under $MIGRATIONS_DIR (colon-separated paths). Each file
# matches Vnnn__name.sql, runs ONCE per DB, tracked in auth.schema_migrations.
# One transaction per file → failure aborts everything and the version row
# stays unset, so the next run retries.
# Default: a "migrations" sibling of each entry in $SQL_DIR (deduped).
default_migrations=""
oldifs="$IFS"; IFS=:
for d in $SQL_DIR; do
  cand="$(dirname "$d")/migrations"
  [ -d "$cand" ] || continue
  case ":$default_migrations:" in *":$cand:"*) ;; *)
    [ -z "$default_migrations" ] && default_migrations="$cand" \
                                 || default_migrations="$default_migrations:$cand"
  ;; esac
done
IFS="$oldifs"
MIGRATIONS_DIR="${BOOTSTRAP_MIGRATIONS_DIR:-$default_migrations}"

if [ -n "$MIGRATIONS_DIR" ]; then
  echo "iam-bootstrap: running migrations from $MIGRATIONS_DIR ..."
  oldifs="$IFS"; IFS=:
  for d in $MIGRATIONS_DIR; do
    [ -d "$d" ] && find "$d" -maxdepth 1 -type f -name 'V*.sql'
  done | awk -F/ '{print $NF "\t" $0}' | sort | cut -f2- | while read -r f; do
    v=$(basename "$f" .sql)
    applied=$(psql -tAc "SELECT 1 FROM auth.schema_migrations WHERE version = '$v'" 2>/dev/null || echo "")
    if [ "$applied" = "1" ]; then
      echo "  · $v already applied"
      continue
    fi
    echo "  → $v ($(dirname "$f"))"
    # \i runs inside the BEGIN/COMMIT block; psql still honours ON_ERROR_STOP.
    psql -v ON_ERROR_STOP=1 <<SQL
BEGIN;
\i $f
INSERT INTO auth.schema_migrations (version) VALUES ('$v');
COMMIT;
SQL
  done
  IFS="$oldifs"
else
  echo "iam-bootstrap: no migrations dir found (skipping)"
fi

# ----------------------------------------------- Permissions self-assert ---
# The auth.* anchor tables must NOT be reachable directly from web_user.
# Everything goes through SECURITY DEFINER functions; this is the core
# invariant the IAM contract rests on. Hard-fail if something granted them.
echo "iam-bootstrap: verifying auth.* table grants ..."
for t in organizations users user_roles; do
  for priv in INSERT UPDATE DELETE SELECT; do
    has=$(psql -tAc "SELECT has_table_privilege('web_user', 'auth.$t', '$priv')")
    if [ "$has" = "t" ]; then
      echo "  FAIL: web_user has $priv on auth.$t (must not)"
      exit 1
    fi
  done
done
# And nobody should have introduced role-catalog RPCs:
for fn in create_role delete_role; do
  exists=$(psql -tAc "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.proname='$fn' AND n.nspname IN ('auth','public')")
  if [ "$exists" != "0" ]; then
    echo "  FAIL: unexpected RPC $fn exists (roles must not be mutable as a catalog)"
    exit 1
  fi
done
echo "iam-bootstrap: auth.* permissions look correct."

# =========================================================================
# Phase 2 — ONCE (gated by /shared/iam-bootstrap.done).
# Skipped on upgrades; iam.env / config.json persist from first run.
# =========================================================================
if [ -f "$SHARED/iam-bootstrap.done" ]; then
  echo "iam-bootstrap: Zitadel-side setup already done — schema/migrations applied, exiting."
  exit 0
fi

# ----------------------------------------------------- Zitadel: Org/User ---
echo "iam-bootstrap: creating Zitadel organization '$ORG_NAME' ..."
ORG_BODY=$(jq -nc --arg n "$ORG_NAME" '{name:$n}')
ORG_ID=$(api POST /v2/organizations "$ORG_BODY" | jq -r '.organizationId')
[ -n "$ORG_ID" ] && [ "$ORG_ID" != "null" ] || { echo "org creation failed"; exit 1; }
echo "  ORG_ID=$ORG_ID"

echo "iam-bootstrap: creating org owner '$OWNER_EMAIL' ..."
OWNER_BODY=$(jq -nc \
  --arg g "$OWNER_GIVEN" --arg f "$OWNER_FAMILY" \
  --arg e "$OWNER_EMAIL" --arg p "$OWNER_PW" '
  {profile:{givenName:$g,familyName:$f},
   email:{email:$e,isVerified:true},
   password:{password:$p,changeRequired:false}}')
OWNER_USER_ID=$(api POST /v2/users/human "$OWNER_BODY" "x-zitadel-orgid: $ORG_ID" | jq -r '.userId')
[ -n "$OWNER_USER_ID" ] && [ "$OWNER_USER_ID" != "null" ] || { echo "owner creation failed"; exit 1; }
echo "  OWNER_USER_ID=$OWNER_USER_ID"

echo "iam-bootstrap: granting Zitadel ORG_OWNER membership ..."
api POST /management/v1/orgs/me/members \
  "$(jq -nc --arg u "$OWNER_USER_ID" '{userId:$u, roles:["ORG_OWNER"]}')" \
  "x-zitadel-orgid: $ORG_ID" >/dev/null \
  && echo "  ✓ $OWNER_USER_ID is ORG_OWNER in $ORG_ID" \
  || echo "  · already ORG_OWNER (or other 4xx)"

echo "iam-bootstrap: creating project '$PROJ_NAME' + OIDC app '$APP_NAME' ..."
PROJ_BODY=$(jq -nc --arg n "$PROJ_NAME" '{name:$n}')
PROJ_ID=$(api POST /management/v1/projects "$PROJ_BODY" "x-zitadel-orgid: $ORG_ID" | jq -r '.id')
[ -n "$PROJ_ID" ] && [ "$PROJ_ID" != "null" ] || { echo "project creation failed"; exit 1; }

APP_BODY=$(jq -nc \
  --arg n "$APP_NAME" \
  --arg r "$LOGIN_ORIGIN/" \
  --arg cb "$LOGIN_ORIGIN/callback" '
  {name:$n,
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
CLIENT_ID=$(api POST "/management/v1/projects/$PROJ_ID/apps/oidc" "$APP_BODY" "x-zitadel-orgid: $ORG_ID" | jq -r '.clientId')
[ -n "$CLIENT_ID" ] && [ "$CLIENT_ID" != "null" ] || { echo "app creation failed"; exit 1; }
echo "  PROJ_ID=$PROJ_ID  CLIENT_ID=$CLIENT_ID"

# --------------------------------------------------------- DB mirror seed ---
echo "iam-bootstrap: seeding auth.* mirror for the org + owner ..."
psql -v ON_ERROR_STOP=1 <<SQL
INSERT INTO auth.organizations (zitadel_org_id, name) VALUES ('$ORG_ID', '$ORG_NAME')
  ON CONFLICT (zitadel_org_id) DO UPDATE SET name = EXCLUDED.name;
INSERT INTO auth.users (zitadel_sub, org_id, email) VALUES
  ('$OWNER_USER_ID',
   (SELECT id FROM auth.organizations WHERE zitadel_org_id = '$ORG_ID'),
   '$OWNER_EMAIL')
  ON CONFLICT (zitadel_sub) DO UPDATE SET email = EXCLUDED.email;
INSERT INTO auth.user_roles (user_id, role)
  SELECT id, '$ORG_ADMIN_ROLE' FROM auth.users WHERE zitadel_sub = '$OWNER_USER_ID'
  ON CONFLICT DO NOTHING;
SQL

# -------------------------------------------------- Outputs for next steps ---
# Minimal SPA runtime config — enough for the app to boot in production.
# An app-specific bootstrap (e.g. examples/products/bootstrap/) may overwrite
# this with extra blocks (demo users, theme, etc.).
POSTGREST_URL="${POSTGREST_URL:-http://localhost:${POSTGREST_PORT:-3001}}"
cat > "$SHARED/config.json" <<EOF
{
  "postgrest": { "url": "${POSTGREST_URL}" },
  "oidc": {
    "issuer": "${ISSUER}",
    "clientId": "${CLIENT_ID}",
    "redirectPath": "/callback",
    "scope": "openid profile email urn:zitadel:iam:user:resourceowner urn:zitadel:iam:org:project:id:zitadel:aud"
  }
}
EOF
echo "iam-bootstrap: wrote $SHARED/config.json (minimal SPA runtime config)"

# Quoted so values with whitespace (e.g. org name "Company A") source cleanly.
shq() { printf "'%s'\n" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
cat > "$SHARED/iam.env" <<EOF
IAM_DB_NAME=$(shq "$DB_NAME")
IAM_ORG_ID=$(shq "$ORG_ID")
IAM_ORG_NAME=$(shq "$ORG_NAME")
IAM_OWNER_USER_ID=$(shq "$OWNER_USER_ID")
IAM_OWNER_EMAIL=$(shq "$OWNER_EMAIL")
IAM_OWNER_GIVEN_NAME=$(shq "$OWNER_GIVEN")
IAM_OWNER_FAMILY_NAME=$(shq "$OWNER_FAMILY")
IAM_PROJECT_ID=$(shq "$PROJ_ID")
IAM_CLIENT_ID=$(shq "$CLIENT_ID")
IAM_ISSUER=$(shq "$ISSUER")
IAM_LOGIN_ORIGIN=$(shq "$LOGIN_ORIGIN")
IAM_ORG_ADMIN_ROLE=$(shq "$ORG_ADMIN_ROLE")
EOF
echo "iam-bootstrap: wrote $SHARED/iam.env"

# ---------------------------------------------------------------------------
# Extension-Point fuer projekt-spezifische IAM-Erweiterungen.
#
# Die Library bleibt generisch (Org+Project+OIDC-App-Setup). Projekte koennen
# zusaetzliche Schritte (Roles, Service-User, PAT, custom Grants) ueber ein
# Skript /scripts/project-bootstrap.sh einklinken. Default: kein Hook
# vorhanden -> noop.
#
# Das Hook-Skript erbt die Lib-Environment-Variablen (PAT, ORG_ID, PROJ_ID,
# API, SHARED, ...). Idempotenz muss das Hook-Skript selbst regeln (eigener
# Sentinel im $SHARED).
# ---------------------------------------------------------------------------
PROJECT_HOOK="${PROJECT_BOOTSTRAP_HOOK:-/scripts/project-bootstrap.sh}"
if [ -f "$PROJECT_HOOK" ]; then
  echo "iam-bootstrap: running project hook $PROJECT_HOOK ..."
  export PAT API ORG_ID PROJ_ID CLIENT_ID OWNER_USER_ID OWNER_EMAIL SHARED \
         ISSUER LOGIN_ORIGIN ORG_NAME ORG_ADMIN_ROLE
  if ! sh "$PROJECT_HOOK"; then
    echo "iam-bootstrap: project hook failed -- aborting"
    exit 1
  fi
  echo "iam-bootstrap: project hook done."
else
  echo "iam-bootstrap: no project hook at $PROJECT_HOOK -- skipping"
fi

touch "$SHARED/iam-bootstrap.done"
echo "iam-bootstrap: done."
