# E2E tests

Playwright tests for the reference app (`examples/products/`). They exercise the **base library** through the real browser → Zitadel OIDC → PostgREST → RLS → provisioning loop.

## Workflow wrapper — `scripts/e2e.sh`

Most things go through one entry point so iteration stays fast and Zitadel state survives between runs:

```bash
scripts/e2e.sh dev        # first time: build lib + app, start stack in dev mode (web is bind-mounted)
scripts/e2e.sh test       # run the suite

# tight iteration on lib/UI code (no docker rebuild):
scripts/e2e.sh iter       # rebuild lib + app on host, run tests

# SQL change to a CREATE OR REPLACE function:
scripts/e2e.sh reapply    # re-applies 01_auth_schema.sql + 02_provisioning.sql into the live DB

# only when you change anchor schema (tables/DDL):
scripts/e2e.sh reset      # destructive: down -v + up (re-bootstraps Zitadel + Postgres)

scripts/e2e.sh status     # show current mode + container state
scripts/e2e.sh help       # full sub-command list
```

`dev` mode mounts the host-built `examples/products/web/dist/browser` into a plain `python:3-alpine` container — there's no `docker build` per iteration, just `npm run build` on the host.

`up` mode (production-equivalent) builds the web image inside Docker, mirroring what the proxvex packaging produces. Use `scripts/e2e.sh up` instead of `dev` when you want to test the real Docker build path.

## Manual invocations (if you skip the wrapper)

```bash
docker compose up -d
docker compose logs -f bootstrap                 # wait for "bootstrap: done."
npm run test:e2e:install                         # once per machine: Chromium
npm run test:e2e                                 # headless
npm run test:e2e:ui                              # interactive
```

## What the tests cover

| File                          | What it asserts                                                      |
| ----------------------------- | -------------------------------------------------------------------- |
| `smoke.spec.ts`               | Landing page renders, "Login" visible, demo-user list shown.         |
| `login.spec.ts`               | Real Zitadel OIDC login (alice). Profile signal shows org + roles.   |
| `tenant-isolation.spec.ts`    | alice sees only Company-A products; carol only Company-B.            |
| `admin-provisioning.spec.ts`  | alice (org_owner) opens `/admin/users`, lists, adds a new user.      |
| `role-guard.spec.ts`          | bob (customer, no org_owner) is bounced from `/admin/users`.         |

## Helpers

- `helpers/login.ts` — drives the Zitadel login UI (loginName → password → consent if any), then waits for the SPA's `whoami` profile signal to populate.
- Demo credentials read from `config.json` at runtime so the tests don't hardcode them.
