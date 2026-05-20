#!/bin/sh
# pack-for-proxvex.sh — bundle an Angular SPA + the base SQL schema into a
# self-contained tarball that proxvex can deploy (nginx web root + bootstrap).
#
# Generic over the consuming app. Inputs are paths; the script:
#   1. Builds the library (ng-packagr) so we have a fresh dist/ + SQL assets.
#   2. Builds the consumer's Angular app (npm install + npm run build).
#   3. Collects: web/ (built SPA), bootstrap/db/*.sql (base + app), bootstrap/bootstrap.sh.
#   4. Produces dist/<out-name>-proxvex.tgz.
#
# Layout of the produced tarball:
#   web/                       # static SPA — drop into nginx web root
#   bootstrap/
#     bootstrap.sh             # idempotent Zitadel bootstrap + DB seed
#     db/00_roles.sql
#     db/01_auth_schema.sql
#     db/02_provisioning.sql
#     db/03_<app>.sql ...      # app-specific SQL (any number, prefixed >= 03)
#
# Usage:
#   examples/packaging/pack-for-proxvex.sh \
#     --app-dir examples/products/web \
#     --bootstrap examples/products/bootstrap/bootstrap.sh \
#     --app-sql  examples/products/db \
#     --out      products
#
# All paths may be relative to the base repo (where this script lives) or absolute.

set -eu

LIB_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR=""
BOOTSTRAP=""
APP_SQL=""
OUT_NAME="app"

while [ $# -gt 0 ]; do
  case "$1" in
    --app-dir)    APP_DIR="$2"; shift 2 ;;
    --bootstrap)  BOOTSTRAP="$2"; shift 2 ;;
    --app-sql)    APP_SQL="$2"; shift 2 ;;
    --out)        OUT_NAME="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -eu/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$APP_DIR" ]   || { echo "missing --app-dir" >&2; exit 2; }
[ -n "$BOOTSTRAP" ] || { echo "missing --bootstrap" >&2; exit 2; }
[ -n "$APP_SQL" ]   || { echo "missing --app-sql (directory containing app SQL files)" >&2; exit 2; }

# Resolve to absolute paths.
abspath() { case "$1" in /*) echo "$1" ;; *) echo "$LIB_REPO/$1" ;; esac; }
APP_DIR="$(abspath "$APP_DIR")"
BOOTSTRAP="$(abspath "$BOOTSTRAP")"
APP_SQL="$(abspath "$APP_SQL")"

OUT_DIR="$LIB_REPO/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

LIB_DIST="$LIB_REPO/dist/zitadel-pgrst-auth-angular"
LIB_DB="$LIB_DIST/assets/db"

echo "pack: (1/4) building library ..." >&2
(cd "$LIB_REPO" && npm run build:lib --silent)

echo "pack: (2/4) building app at $APP_DIR ..." >&2
(cd "$APP_DIR" && npm install --no-audit --no-fund --silent && npm run build --silent)

# Locate the produced static site. Convention: dist/ inside the app dir.
APP_OUT="$(find "$APP_DIR/dist" -mindepth 1 -maxdepth 2 -type d -name browser -print -quit || true)"
if [ -z "$APP_OUT" ]; then
  APP_OUT="$(find "$APP_DIR/dist" -mindepth 1 -maxdepth 1 -type d -print -quit || true)"
fi
[ -n "$APP_OUT" ] || { echo "pack: could not find built SPA under $APP_DIR/dist" >&2; exit 1; }

echo "pack: (3/4) staging tarball ..." >&2
mkdir -p "$STAGE/web" "$STAGE/bootstrap/db"
cp -R "$APP_OUT"/. "$STAGE/web/"
cp "$BOOTSTRAP" "$STAGE/bootstrap/bootstrap.sh"
chmod +x "$STAGE/bootstrap/bootstrap.sh"
cp "$LIB_DB/00_roles.sql"          "$STAGE/bootstrap/db/00_roles.sql"
cp "$LIB_DB/01_auth_schema.sql"    "$STAGE/bootstrap/db/01_auth_schema.sql"
cp "$LIB_DB/02_provisioning.sql"   "$STAGE/bootstrap/db/02_provisioning.sql"
# App SQL: copy every *.sql, alphabetically. Convention: name them 03_*, 04_* etc.
find "$APP_SQL" -maxdepth 1 -type f -name '*.sql' | sort | while read -r f; do
  cp "$f" "$STAGE/bootstrap/db/$(basename "$f")"
done

echo "pack: (4/4) creating tarball ..." >&2
mkdir -p "$OUT_DIR"
TGZ="$OUT_DIR/${OUT_NAME}-proxvex.tgz"
tar -C "$STAGE" -czf "$TGZ" web bootstrap

echo "pack: done -> $TGZ" >&2
tar -tzf "$TGZ" | sed 's/^/  /' >&2
