#!/bin/sh
# Orchestrator — läuft EINMAL bei Postgres-Erstinitialisierung
# (docker-entrypoint-initdb.d). Spielt die Basis-/App-SQL in fester Reihenfolge
# mit ON_ERROR_STOP ein und reicht das Authenticator-Passwort als psql-Variable
# durch (versionsunabhängig, kein \getenv nötig).
set -eu

: "${AUTHENTICATOR_PASSWORD:?AUTHENTICATOR_PASSWORD muss gesetzt sein}"

for f in /sql/00_roles.sql /sql/01_auth_schema.sql /sql/02_app_products.sql; do
  echo "init.sh: applying $f"
  psql -v ON_ERROR_STOP=1 \
       -v authpw="$AUTHENTICATOR_PASSWORD" \
       --username "$POSTGRES_USER" \
       --dbname "$POSTGRES_DB" \
       -f "$f"
done

echo "init.sh: Basis-Schema + Beispiel-App eingespielt."
