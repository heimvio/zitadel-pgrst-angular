# zitadel-pgrst-auth — deployable package

Self-contained artifact produced by `package/build.sh`:

```
zitadel-pgrst-auth.tgz
├── web/                    # built Angular app (static) — serve from nginx web root
├── bootstrap/
│   ├── bootstrap.sh        # idempotent Zitadel bootstrap + DB seed; writes
│   │                       #   web/config.json (issuer/clientId/postgrest)
│   └── db/
│       ├── 00_roles.sql        # PostgREST roles (web_user/authenticator)
│       ├── 01_auth_schema.sql  # generic auth core (Single Source of Truth)
│       └── 02_products.sql     # example app schema + RLS
└── PACKAGE.md              # this file
```

## How proxvex consumes it

1. Upload the tar; extract `web/` into the **nginx** application's web root
   (static SPA, serves `/` + `config.json`).
2. Apply the DB schema once, in order, as the `postgres` superuser against the
   app database:
   `bootstrap/db/00_roles.sql` → `01_auth_schema.sql` → `02_products.sql`
   (idempotent, `ON_ERROR_STOP`-safe). Equivalent to the shared
   `331-provision-auth-rls` template for the generic core.
3. Run `bootstrap/bootstrap.sh` (needs the Zitadel API + a PAT, and `psql`
   access to the DB). It creates the Zitadel orgs/users/OIDC-app, seeds
   `auth.*` + example data, and writes `web/config.json` so the static app
   knows issuer/clientId/PostgREST URL. Idempotent (guarded by
   `bootstrap.done`).

PostgREST itself is the standard proxvex PostgREST app with
`PGRST_DB_PRE_REQUEST=auth.ensure_principal` and
`PGRST_JWT_SECRET=@/jwks/jwks.json` (JWKS kept fresh by the
`341-post-install-jwks-refresh-on-start` hook). See the proxvex
`postgrest/application.md` → *zitadel-pgrst-auth integration*.

The result: the whole example app installs from one uploaded tar.
