#!/usr/bin/env bash
# e2e.sh — single entry point to spin up the stack, iterate quickly, and run
# the Playwright E2E suite.
#
# Two operating modes for the `web` container:
#
#   - **prod** (default): web image is built by Docker. First-time setup is
#     slow (~2 min cold) and every code change requires `docker compose build`.
#     Use this to mirror what production deploys.
#
#   - **dev**: web container is a plain `python:3-alpine` that serves the
#     host-built dist/ via a bind-mount. After the first up, every iteration
#     is local: `scripts/e2e.sh iter` rebuilds lib + app on the host
#     (~10-15 s) and the container picks up the changes immediately. Zitadel
#     and Postgres state survive — no re-bootstrap.
#
# Sub-commands:
#
#   up          start the stack in prod mode (web is the Docker-built image)
#   build       force-rebuild the web image (use after Dockerfile changes)
#   dev         start the stack in dev mode (web bind-mounts host dist/) AND
#               run disable-mfa so the headless OIDC flow can complete
#   iter        fast loop: rebuild lib + app on the host, then run e2e tests
#               (dev mode only — picks up changes via bind-mount)
#   reapply     re-run 01_auth_schema.sql + 02_provisioning.sql against the
#               live DB (works because every function uses CREATE OR REPLACE).
#               Reloads the PostgREST schema cache afterwards.
#   refresh     re-run bootstrap.sh inside the bootstrap container, without
#               dropping pgdata or Zitadel state (deletes the bootstrap.done
#               sentinel so the seed runs again — itself idempotent via
#               ON CONFLICT). Use after bootstrap.sh changed (e.g. new role,
#               new scope) but the data is otherwise fine.
#   disable-mfa relax the instance default login policy so the e2e tests
#               aren't blocked by 2-Factor setup/verify prompts. Test-only;
#               separate from the production-deliverable bootstrap.sh.
#               Idempotent.
#   test        just run the playwright suite against whatever's running
#   reset       docker compose down -v && up (destroys pgdata + Zitadel state)
#   status      what's running, which mode
#   help        this text
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEV_OVERLAY=("-f" "docker-compose.yml" "-f" "docker-compose.dev.yml")
MODE_FILE="$ROOT/.e2e-mode"
LIB_DB="projects/zitadel-pgrst-angular/assets/db"

# ----------------------------------------------------------------------------
log()   { printf '\033[1;34m[e2e]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[e2e]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[e2e]\033[0m %s\n' "$*" >&2; exit 1; }

current_mode() {
  if [ -f "$MODE_FILE" ]; then cat "$MODE_FILE"; else echo "prod"; fi
}

compose() {
  if [ "$(current_mode)" = "dev" ]; then
    docker compose "${DEV_OVERLAY[@]}" "$@"
  else
    docker compose "$@"
  fi
}

build_local() {
  log "building library …"
  npm run build:lib --silent
  log "building example app …"
  ( cd examples/products/web \
    && npm install --no-audit --no-fund --silent \
    && npm run build --silent )
  # `ng build` wipes dist/browser, so re-stage the runtime config from the
  # shared volume (in dev mode the python server reads dist/browser:ro).
  if docker volume inspect zitadel-pgrst-angular_shared >/dev/null 2>&1; then
    docker run --rm -v zitadel-pgrst-angular_shared:/shared:ro alpine:3.20 \
      cat /shared/config.json > examples/products/web/dist/browser/config.json \
      2>/dev/null \
      && log "config.json restaged to dist/browser/"
  fi
}

wait_for_bootstrap() {
  log "waiting for bootstrap to finish …"
  local i=0
  while [ $i -lt 180 ]; do
    if compose logs --no-color bootstrap 2>/dev/null | grep -q 'bootstrap: done\.'; then
      log "bootstrap: done."
      return 0
    fi
    if compose logs --no-color bootstrap 2>/dev/null | grep -qi 'already initialised'; then
      log "bootstrap: already initialised."
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  die "bootstrap did not finish within 180s — check 'compose logs bootstrap'"
}

ensure_playwright() {
  if [ ! -d node_modules/@playwright ]; then
    log "installing workspace node_modules …"
    npm install --no-audit --no-fund --silent
  fi
  if [ ! -d "$HOME/Library/Caches/ms-playwright" ] \
     && [ ! -d "$HOME/.cache/ms-playwright" ]; then
    log "downloading Chromium (one-off) …"
    npx playwright install --with-deps chromium
  fi
}

reapply_sql() {
  log "re-applying 01_auth_schema.sql + 02_provisioning.sql …"
  # 00_roles.sql is skipped: it needs :authpw and changes practically never.
  for f in 01_auth_schema.sql 02_provisioning.sql; do
    log "  $f"
    docker compose exec -T postgres \
      psql -v ON_ERROR_STOP=1 -U postgres -d appdb < "$LIB_DB/$f" >/dev/null
  done
  log "reloading PostgREST schema cache …"
  docker compose exec -T postgres psql -U postgres -d appdb \
    -c "NOTIFY pgrst, 'reload schema';" >/dev/null
}

run_disable_mfa() {
  if [ -x e2e/helpers/disable-mfa.sh ]; then
    log "running e2e/helpers/disable-mfa.sh …"
    e2e/helpers/disable-mfa.sh >/dev/null && log "  ✓ MFA policy relaxed." \
      || warn "  · disable-mfa exited non-zero (continuing)"
  fi
}

# ----------------------------------------------------------------------------
cmd_up() {
  echo "prod" > "$MODE_FILE"
  log "starting stack in PROD mode …"
  docker compose up -d
  wait_for_bootstrap
  log "ready → http://localhost:8089"
}

cmd_build() {
  log "rebuilding web image (Docker) …"
  docker compose build web
  docker compose up -d web
  log "web image rebuilt + restarted."
}

cmd_refresh() {
  log "re-running bootstrap (preserves DB + Zitadel state) …"
  # Drop the sentinel by mounting the shared volume into a throwaway helper.
  docker compose run --rm --no-deps --entrypoint sh \
    -v zitadel-pgrst-angular_shared:/shared bootstrap \
    -c 'rm -f /shared/bootstrap.done && echo "bootstrap.done cleared"' || true
  docker compose up -d --force-recreate bootstrap
  wait_for_bootstrap
}

cmd_dev() {
  build_local
  echo "dev" > "$MODE_FILE"
  log "starting stack in DEV mode (web served from host dist/) …"
  docker compose "${DEV_OVERLAY[@]}" up -d
  wait_for_bootstrap
  run_disable_mfa
  log "ready → http://localhost:8089 (dev mode, bind-mount on dist/)"
}

cmd_iter() {
  if [ "$(current_mode)" != "dev" ]; then
    warn "current mode is '$(current_mode)' — iter only makes sense in dev mode."
    warn "run 'scripts/e2e.sh dev' first."
    exit 2
  fi
  build_local
  # nginx-equivalent isn't needed: the python server reads from disk on each request.
  # Postgres might already have the schema → user can reapply explicitly with 'reapply'.
  cmd_test
}

cmd_reapply() {
  reapply_sql
}

cmd_test() {
  ensure_playwright
  log "running playwright suite …"
  npm run test:e2e
}

cmd_reset() {
  log "tearing down (incl. volumes) …"
  compose down -v
  if [ "$(current_mode)" = "dev" ]; then cmd_dev; else cmd_up; fi
}

cmd_status() {
  log "mode: $(current_mode)"
  compose ps
}

cmd_help() { sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-help}" in
  up)          cmd_up ;;
  build)       cmd_build ;;
  dev)         cmd_dev ;;
  iter)        cmd_iter ;;
  reapply)     cmd_reapply ;;
  refresh)     cmd_refresh ;;
  disable-mfa) run_disable_mfa ;;
  test)        cmd_test ;;
  reset)       cmd_reset ;;
  status)      cmd_status ;;
  help|-h|--help) cmd_help ;;
  *) die "unknown command: $1 (try 'help')" ;;
esac
