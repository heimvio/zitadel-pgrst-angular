# Base / IAM bootstrap

Reusable, app-agnostic provisioning of **one tenant** on top of Zitadel +
Postgres. Same script runs in the demo `docker compose` and in production
(proxvex). Everything app-specific stays in `examples/products/bootstrap/`.

## What it does (idempotent)

1. Refreshes `/shared/jwks.json` and disables Zitadel LoginV2 (instance feature).
2. Creates the Postgres database (`iam.databaseName`, default = slug of
   `iam.orgName`).
3. Applies the core auth SQL from `projects/zitadel-pgrst-angular/assets/db/`:
   `00_roles.sql`, `01_auth_schema.sql`, `02_provisioning.sql`.
4. Optionally overrides `auth.org_admin_role()` with a custom role name
   (e.g. `hausverwaltung`).
5. **Self-asserts** the auth invariant: `web_user` has no direct table grants
   on `auth.organizations / users / user_roles` and there are no
   `create_role` / `delete_role` RPCs (roles are not a mutable catalog).
6. Creates the Zitadel organization (`iam.orgName`).
7. Creates the first org-owner human user and grants Zitadel `ORG_OWNER`
   membership.
8. Creates the Zitadel project (`iam.projectName`, default = org name) and an
   OIDC SPA app (`iam.appName`, default = org name).
9. Mirrors org + owner into `auth.organizations / users / user_roles` (with
   the configured admin role).
10. Writes outputs for downstream consumers:
    - `/shared/iam.env` — IDs needed by the example bootstrap or the SPA.
    - `/shared/iam-bootstrap.done` — sentinel; re-runs only refresh JWKS.

## Configuration — `bootstrap/config.json`

```json
{
  "iam": {
    "databaseName": "appdb",          // optional; default = slug(orgName)
    "orgName": "Company A",            // required
    "projectName": null,               // optional; default = orgName
    "appName": null,                   // optional; default = orgName
    "orgAdminRole": "org_owner",       // DB role name; e.g. "hausverwaltung"
    "loginOrigin": "http://localhost:8089",
    "orgOwner": {                      // all four required
      "givenName": "Alice",
      "familyName": "Staff",
      "email": "alice@a.demo",
      "password": "Demo1!Pass"
    }
  },
  "app": { /* consumed by examples/products/bootstrap/bootstrap.sh */ }
}
```

The `app:` section is **opaque** to this script. Apps own their own keys
under it; here it's just passed through to the next stage.

## Environment

| Variable                  | Purpose                                                       |
| ------------------------- | ------------------------------------------------------------- |
| `ZITADEL_API`             | internal Zitadel base URL (e.g. `http://zitadel:8080`)        |
| `ZITADEL_ISSUER`          | external issuer (goes into the SPA's `config.json`)           |
| `PGHOST` / `PGUSER` / `PGPASSWORD` | Postgres admin (needs `CREATE DATABASE`)             |
| `AUTHENTICATOR_PASSWORD`  | password for the PostgREST login role                         |
| `BOOTSTRAP_CONFIG`        | path to config.json (default `/config/config.json`)           |
| `BOOTSTRAP_SQL_DIR`       | dir holding `00/01/02_*.sql` (default `/sql/auth`)            |
| `BOOTSTRAP_SHARED`        | output dir (default `/shared`)                                |
| `BOOTSTRAP_PAT_FILE`      | Zitadel admin PAT path (default `/bootstrap/admin-client.pat`)|

## Standalone use (without docker-compose)

```bash
docker run --rm \
  --network host \
  -e ZITADEL_API=https://login.example.com \
  -e ZITADEL_ISSUER=https://login.example.com \
  -e PGHOST=... -e PGUSER=postgres -e PGPASSWORD=... \
  -e AUTHENTICATOR_PASSWORD=... \
  -v "$PWD/bootstrap/config.json:/config/config.json:ro" \
  -v "$PWD/projects/zitadel-pgrst-angular/assets/db:/sql/auth:ro" \
  -v /var/secrets/zitadel-admin.pat:/bootstrap/admin-client.pat:ro \
  -v iam_shared:/shared \
  -w / \
  alpine:3.20 sh /scripts/bootstrap.sh
```

## Outputs (`/shared/iam.env`)

```
IAM_DB_NAME=appdb
IAM_ORG_ID=<zitadel-org-id>
IAM_ORG_NAME=Company A
IAM_OWNER_USER_ID=<zitadel-user-id>
IAM_OWNER_EMAIL=alice@a.demo
IAM_PROJECT_ID=<zitadel-project-id>
IAM_CLIENT_ID=<oidc-client-id>
IAM_ISSUER=http://localhost:8088
IAM_LOGIN_ORIGIN=http://localhost:8089
IAM_ORG_ADMIN_ROLE=org_owner
```
