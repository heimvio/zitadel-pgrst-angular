#!/bin/sh
# Orchestrator — runs ONCE on first Postgres initialisation
# (docker-entrypoint-initdb.d). Applies the core/app SQL in a fixed order with
# ON_ERROR_STOP and passes the authenticator password as a psql variable
# (version-independent, no \getenv needed).
set -eu

: "${AUTHENTICATOR_PASSWORD:?AUTHENTICATOR_PASSWORD must be set}"

# Order: generic CORE (auth/) first, then the example app (example/).
for f in /sql/auth/00_roles.sql /sql/auth/01_auth_schema.sql /sql/example/02_products.sql; do
  echo "init.sh: applying $f"
  psql -v ON_ERROR_STOP=1 \
       -v authpw="$AUTHENTICATOR_PASSWORD" \
       --username "$POSTGRES_USER" \
       --dbname "$POSTGRES_DB" \
       -f "$f"
done

echo "init.sh: core schema + example app applied."
