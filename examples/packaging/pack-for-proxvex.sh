#!/bin/sh
# pack-for-proxvex.sh — bundle an Angular SPA + base SQL + IAM bootstrap into
# a self-contained tarball that proxvex (or any plain host) can deploy: drop
# `web/` into nginx, run `bootstrap/run.sh` once.
#
# Two-stage bootstrap (since the IAM split):
#   - base.sh: app-agnostic, creates DB + auth schema + Zitadel org/project/
#     app + first org owner. ALWAYS runs.
#   - app.sh:  optional, app-specific seed (extra orgs, demo users, products).
#     Only shipped if --app-bootstrap was passed at pack time.
#
# Layout of the produced tarball:
#   web/                          # static SPA — drop into nginx web root
#   bootstrap/
#     config.json                 # IAM + (optional) app config — edit before run
#     base.sh                     # required
#     app.sh                      # only if --app-bootstrap given
#     run.sh                      # wrapper: base then app (skips app if absent)
#     README.md                   # how to set env vars and run
#     db/00_roles.sql
#     db/01_auth_schema.sql
#     db/02_provisioning.sql
#     db/02_<app>.sql ...         # app-specific definition SQL
#     migrations/Vnnn__*.sql      # lib + app delta migrations, tracked in
#                                 # auth.schema_migrations (one-shot per file)
#
# Usage:
#   examples/packaging/pack-for-proxvex.sh \
#     --app-dir         examples/products/web \
#     --base-bootstrap  bootstrap/bootstrap.sh \
#     --config          bootstrap/config.json \
#     --app-bootstrap   examples/products/bootstrap/bootstrap.sh \
#     --app-sql         examples/products/db \
#     --out             products
#
# Minimal (production, no demo seed): omit --app-bootstrap.
# All paths may be relative to the repo root or absolute.

set -eu

LIB_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR=""
BASE_BOOTSTRAP="$LIB_REPO/bootstrap/bootstrap.sh"
CONFIG="$LIB_REPO/bootstrap/config.json"
APP_BOOTSTRAP=""
APP_SQL=""
OUT_NAME="app"

while [ $# -gt 0 ]; do
  case "$1" in
    --app-dir)          APP_DIR="$2"; shift 2 ;;
    --base-bootstrap)   BASE_BOOTSTRAP="$2"; shift 2 ;;
    --config)           CONFIG="$2"; shift 2 ;;
    --app-bootstrap)    APP_BOOTSTRAP="$2"; shift 2 ;;
    --bootstrap)        APP_BOOTSTRAP="$2"; shift 2 ;;  # legacy alias
    --app-sql)          APP_SQL="$2"; shift 2 ;;
    --out)              OUT_NAME="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -eu/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$APP_DIR" ] || { echo "missing --app-dir" >&2; exit 2; }
[ -n "$APP_SQL" ] || { echo "missing --app-sql (directory containing app SQL files)" >&2; exit 2; }

abspath() { case "$1" in /*) echo "$1" ;; *) echo "$LIB_REPO/$1" ;; esac; }
APP_DIR="$(abspath "$APP_DIR")"
APP_SQL="$(abspath "$APP_SQL")"
BASE_BOOTSTRAP="$(abspath "$BASE_BOOTSTRAP")"
CONFIG="$(abspath "$CONFIG")"
[ -n "$APP_BOOTSTRAP" ] && APP_BOOTSTRAP="$(abspath "$APP_BOOTSTRAP")"

[ -f "$BASE_BOOTSTRAP" ] || { echo "base bootstrap not found: $BASE_BOOTSTRAP" >&2; exit 1; }
[ -f "$CONFIG" ]         || { echo "config.json not found: $CONFIG" >&2; exit 1; }
[ -z "$APP_BOOTSTRAP" ] || [ -f "$APP_BOOTSTRAP" ] || {
  echo "app bootstrap not found: $APP_BOOTSTRAP" >&2; exit 1; }

OUT_DIR="$LIB_REPO/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

LIB_DIST="$LIB_REPO/dist/zitadel-pgrst-angular"
LIB_DB="$LIB_DIST/assets/db"

echo "pack: (1/4) building library ..." >&2
(cd "$LIB_REPO" && npm run build:lib --silent)

echo "pack: (2/4) building app at $APP_DIR ..." >&2
(cd "$APP_DIR" && npm install --no-audit --no-fund --silent && npm run build --silent)

APP_OUT="$(find "$APP_DIR/dist" -mindepth 1 -maxdepth 2 -type d -name browser -print -quit || true)"
if [ -z "$APP_OUT" ]; then
  APP_OUT="$(find "$APP_DIR/dist" -mindepth 1 -maxdepth 1 -type d -print -quit || true)"
fi
[ -n "$APP_OUT" ] || { echo "pack: could not find built SPA under $APP_DIR/dist" >&2; exit 1; }

echo "pack: (3/4) staging tarball ..." >&2
mkdir -p "$STAGE/web" "$STAGE/bootstrap/db"
cp -R "$APP_OUT"/. "$STAGE/web/"

cp "$BASE_BOOTSTRAP" "$STAGE/bootstrap/base.sh"
chmod +x "$STAGE/bootstrap/base.sh"
cp "$CONFIG"         "$STAGE/bootstrap/config.json"

if [ -n "$APP_BOOTSTRAP" ]; then
  cp "$APP_BOOTSTRAP" "$STAGE/bootstrap/app.sh"
  chmod +x "$STAGE/bootstrap/app.sh"
fi

cp "$LIB_DB/00_roles.sql"          "$STAGE/bootstrap/db/00_roles.sql"
cp "$LIB_DB/01_auth_schema.sql"    "$STAGE/bootstrap/db/01_auth_schema.sql"
cp "$LIB_DB/02_provisioning.sql"   "$STAGE/bootstrap/db/02_provisioning.sql"
find "$APP_SQL" -maxdepth 1 -type f -name '*.sql' | sort | while read -r f; do
  cp "$f" "$STAGE/bootstrap/db/$(basename "$f")"
done

# Migrations: merge lib's assets/db/migrations + app's <APP_SQL>/migrations.
# Filenames must not clash (Vnnn__name.sql is the contract).
mkdir -p "$STAGE/bootstrap/migrations"
for d in "$LIB_DB/migrations" "$APP_SQL/migrations"; do
  [ -d "$d" ] || continue
  find "$d" -maxdepth 1 -type f -name 'V*.sql' | sort | while read -r f; do
    cp "$f" "$STAGE/bootstrap/migrations/$(basename "$f")"
  done
done

# ---- run.sh wrapper -------------------------------------------------------
cat > "$STAGE/bootstrap/run.sh" <<'RUN'
#!/bin/sh
# Run the bootstrap stages. Requires env vars (see README.md):
#   ZITADEL_API, ZITADEL_ISSUER, PGHOST, PGUSER, PGPASSWORD,
#   AUTHENTICATOR_PASSWORD, BOOTSTRAP_PAT_FILE.
# Optional: BOOTSTRAP_SHARED (default /shared).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
export BOOTSTRAP_CONFIG="${BOOTSTRAP_CONFIG:-$HERE/config.json}"
export BOOTSTRAP_SQL_DIR="${BOOTSTRAP_SQL_DIR:-$HERE/db}"
export BOOTSTRAP_SHARED="${BOOTSTRAP_SHARED:-/shared}"
mkdir -p "$BOOTSTRAP_SHARED"

echo "run: stage 1/2 — base.sh"
sh "$HERE/base.sh"

if [ -f "$HERE/app.sh" ]; then
  echo "run: stage 2/2 — app.sh"
  sh "$HERE/app.sh"
else
  echo "run: no app.sh in tarball — base only (production layout)."
fi
RUN
chmod +x "$STAGE/bootstrap/run.sh"

# ---- README.md (lives INSIDE the tarball, for the deployer) ---------------
cat > "$STAGE/bootstrap/README.md" <<'README'
# Tarball deploy

Two pieces:

- `web/`        — static SPA. Serve from nginx (or any static host). The app
                  loads `config.json` from its own origin at runtime; the IAM
                  bootstrap writes one into `BOOTSTRAP_SHARED` — copy it next
                  to `index.html` after the bootstrap run.
- `bootstrap/`  — one-shot provisioning, idempotent.

## 1. Edit `bootstrap/config.json`

```json
{
  "iam": {
    "databaseName": "appdb",
    "orgName": "Your Customer Name",
    "orgAdminRole": "org_owner",
    "loginOrigin": "https://app.example.com",
    "orgOwner": { "givenName": "...", "familyName": "...", "email": "...", "password": "<initial>" }
  }
}
```

The `app:` section is consumed only by `app.sh` (if shipped). For a clean
production install, leave `iam:` populated and remove `app:` to skip demo
seeding.

## 2. Required environment

| Variable                 | Purpose                                                          |
| ------------------------ | ---------------------------------------------------------------- |
| `ZITADEL_API`            | internal Zitadel base URL (e.g. `http://zitadel:8080`)           |
| `ZITADEL_ISSUER`         | external issuer (goes into the SPA's `config.json`)              |
| `PGHOST` / `PGUSER` / `PGPASSWORD` | Postgres admin (needs `CREATE DATABASE`)               |
| `AUTHENTICATOR_PASSWORD` | password for the PostgREST login role                            |
| `BOOTSTRAP_PAT_FILE`     | path to a Zitadel admin PAT (with org/project/app + user create) |

Optional: `BOOTSTRAP_SHARED` (default `/shared`) — directory where the IAM
bootstrap writes `iam.env`, `jwks.json`, `config.json`, and the `*.done`
sentinels.

## 3. Run

```sh
sh bootstrap/run.sh
cp "$BOOTSTRAP_SHARED/config.json" web/config.json   # or via your IaC
```

Re-runs are safe (= **upgrade path**): every run refreshes JWKS, re-applies
`db/*.sql` (idempotent), and runs any new files under `migrations/` that
haven't been applied yet (tracked in `auth.schema_migrations`). The Zitadel-
side org/owner/project/app creation is gated by `iam-bootstrap.done` and runs
only on the first deploy.

## Upgrading

1. Extract the new tarball **over** the old one (replaces `web/`, `bootstrap/`).
2. `sh bootstrap/run.sh` again — re-applies the new SQL + any new migrations.
3. Refresh `web/config.json` only if `iam.env` values changed (they normally don't).

## Layout

```
web/                       # built SPA
bootstrap/
  config.json              # edit before first run
  base.sh                  # IAM + DB schema + migrations runner
  app.sh                   # (optional) app-specific seed
  run.sh                   # base.sh then app.sh
  README.md                # this file
  db/                      # idempotent definition SQL (re-applied every run)
    00_roles.sql
    01_auth_schema.sql
    02_provisioning.sql
    02_*.sql               # app definition SQL
  migrations/              # delta SQL (each Vnnn__*.sql runs ONCE per DB)
    V001__*.sql            # tracked in auth.schema_migrations
```
README

echo "pack: (4/4) creating tarball ..." >&2
mkdir -p "$OUT_DIR"
TGZ="$OUT_DIR/${OUT_NAME}-proxvex.tgz"
tar -C "$STAGE" -czf "$TGZ" web bootstrap

echo "pack: done -> $TGZ" >&2
tar -tzf "$TGZ" | sed 's/^/  /' >&2
