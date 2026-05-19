#!/bin/sh
# Build the self-contained deployable package:
#   dist/zitadel-pgrst-auth.tgz  =  web/ (built Angular) + bootstrap/ (script
#   + db schema) + PACKAGE.md  -> upload to proxvex (nginx + bootstrap).
#
# Uses the existing example Dockerfile to build the Angular app (it already
# reconstructs the generic core angular-auth/ as src/auth/). No local Node
# needed — only Docker. Run from the repository root.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IMG=zitadel-pgrst-auth-pkg
OUT="$ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "build: compiling Angular (Docker) ..." >&2
docker build -q -f examples/products/web/Dockerfile -t "$IMG" . >/dev/null

echo "build: extracting static site ..." >&2
cid="$(docker create "$IMG")"
docker cp "$cid:/site" "$STAGE/web" >/dev/null
docker rm -f "$cid" >/dev/null

echo "build: assembling bootstrap + db schema ..." >&2
mkdir -p "$STAGE/bootstrap/db"
cp examples/products/bootstrap/bootstrap.sh "$STAGE/bootstrap/bootstrap.sh"
cp auth/00_roles.sql            "$STAGE/bootstrap/db/00_roles.sql"
cp auth/01_auth_schema.sql      "$STAGE/bootstrap/db/01_auth_schema.sql"
cp examples/products/db/02_products.sql "$STAGE/bootstrap/db/02_products.sql"
cp package/PACKAGE.md           "$STAGE/PACKAGE.md"

mkdir -p "$OUT"
tar -C "$STAGE" -czf "$OUT/zitadel-pgrst-auth.tgz" web bootstrap PACKAGE.md

echo "build: done -> dist/zitadel-pgrst-auth.tgz" >&2
tar -tzf "$OUT/zitadel-pgrst-auth.tgz" | sed 's/^/  /' >&2
