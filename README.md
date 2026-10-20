# zitadel-pgrst-angular

**Reusable building blocks for multi-tenant SaaS** on top of **Zitadel** (identity), **PostgREST** (API), and **Postgres + RLS** (policy). Ships as an Angular library with two entrypoints plus the SQL schema as assets — drop it into a new app and you get login, JIT principal mirror, role-gated UI guards, and admin provisioning out of the box, with no backend.

```text
@heimvio/zitadel-pgrst-angular
├── /auth         — OIDC-PKCE, JIT (ensure_principal), whoami, authInterceptor, authGuard, roleGuard
├── /provisioning — Zitadel mgmt-API client, ProvisioningService, admin UI components, routes
└── assets/db/    — SQL schema files (load into Postgres in order)
                   00_roles.sql · 01_auth_schema.sql · 02_provisioning.sql
```

## Quickstart — build a new app

### 1. Install the library

The package is published to the **GitHub Packages npm registry** under the
`@heimvio` scope (source: <https://github.com/heimvio/zitadel-pgrst-angular>).
GitHub Packages requires a token even for public packages:

```bash
# .npmrc of your project (commit this line, it contains no secret)
@heimvio:registry=https://npm.pkg.github.com

# ~/.npmrc (never commit): a GitHub token with the read:packages scope,
# e.g. a classic PAT or `gh auth token` after `gh auth refresh -s read:packages`
//npm.pkg.github.com/:_authToken=<token>
```

```bash
npm install @heimvio/zitadel-pgrst-angular angular-oauth2-oidc
```

In CI or a Docker build pass the token as a secret (e.g. a BuildKit secret
mounted as `~/.npmrc`), never as a build argument or environment variable that
ends up in an image layer.

During development against a local checkout:

```json
// package.json of your app
"dependencies": {
  "@heimvio/zitadel-pgrst-angular": "file:../zitadel-pgrst-angular/dist/zitadel-pgrst-angular"
}
```

Run `npm run build:lib` in the `zitadel-pgrst-angular` checkout first; then `npm install` in your app picks up the freshly built package. With a `file:` link, set `"preserveSymlinks": true` in your `tsconfig.json` so the library resolves Angular from your app instead of from the checkout.

### 2. Apply the database schema

The library ships SQL as assets under `node_modules/@heimvio/zitadel-pgrst-angular/assets/db/`. Run them in order against your app database (as a superuser):

```bash
DB=postgresql://postgres@localhost/myapp
ROOT=node_modules/@heimvio/zitadel-pgrst-angular/assets/db

psql "$DB" -v authpw="$AUTH_PW" -f "$ROOT/00_roles.sql"
psql "$DB"                       -f "$ROOT/01_auth_schema.sql"
psql "$DB"                       -f "$ROOT/02_provisioning.sql"

# then your own app SQL — use the multi-tenant patterns:
#   org_id uuid NOT NULL DEFAULT auth.org_id()
#   policy USING (org_id = auth.org_id() AND auth.has_role('...'))
psql "$DB"                       -f db/03_myapp.sql
```

### 3. Wire it up in your Angular `main.ts`

```ts
import { bootstrapApplication } from '@angular/platform-browser';
import { provideRouter } from '@angular/router';
import { provideAuth } from '@heimvio/zitadel-pgrst-angular/auth';
import { provideProvisioning, provisioningRoutes } from '@heimvio/zitadel-pgrst-angular/provisioning';
import { AppComponent } from './app.component';

bootstrapApplication(AppComponent, {
  providers: [
    provideRouter([
      // your own routes …
      { path: 'admin', children: provisioningRoutes() }
    ]),
    provideAuth(),
    provideProvisioning({
      rolesCatalog: ['org_owner', 'tenant', 'meter_reader', 'iam_org_owner']
    })
  ]
});
```

### 4. Provide a runtime `config.json`

Ship a `config.json` next to your `index.html` (do not bake it into the bundle — it changes per environment). The library loads it during APP_INITIALIZER:

```json
{
  "postgrest": { "url": "https://api.example.com" },
  "oidc": {
    "issuer":       "https://login.example.com",
    "clientId":     "your-zitadel-spa-client",
    "redirectPath": "/callback",
    "scope":        "openid profile email urn:zitadel:iam:user:resourceowner urn:zitadel:iam:org:project:id:zitadel:aud"
  }
}
```

The last scope (`…:zitadel:aud`) is required so the SPA's access token also works against the Zitadel management API for provisioning calls.

The file is fetched relative to `<base href>` by default. An app served below a
sub path that shares the session of the app at the origin root (for example a
heimvio extension under `/apps/<slug>/`) loads the root file instead, and can
override single values after loading:

```ts
provideAuth({
  configUrl: '/config.json',
  afterConfigLoaded: (cfg) => { cfg.postgrest.url = '/api'; }
})
```

`AuthService.initialized` is a promise that resolves once the code flow has
been processed (signed in or not) — for a second app initializer that must run
after it. `AuthService.login(state?)` passes an optional application state through the
OIDC round trip; after the callback it is available as `OAuthService.state`,
URI-encoded once (read it with `decodeURIComponent`).

### 5. (Optional) Use the admin UI components directly

```ts
// e.g. inside a custom feature component
import { OrgUsersListComponent } from '@heimvio/zitadel-pgrst-angular/provisioning';

@Component({
  imports: [OrgUsersListComponent],
  template: `<base-org-users-list />`
})
```

## Demo

`examples/products/` is a runnable reference app that consumes the library exactly like a new app would (`file:` dependency on `dist/`). After `docker compose up` in the repo root, open <http://localhost:8089> and log in with one of the demo users:

| Login          | Password     | Role        |
| -------------- | ------------ | ----------- |
| `alice@a.demo` | `Demo1!Pass` | staff + org_owner  |
| `bob@a.demo`   | `Demo1!Pass` | customer    |
| `carol@b.demo` | `Demo1!Pass` | staff       |
| `dave@b.demo`  | `Demo1!Pass` | customer    |

`alice` can navigate to `/admin/users` to add a new user to Company-A — confirmation that the provisioning flow round-trips through Zitadel into `auth.users` correctly.

## Distribution — `@heimvio` on GitHub Packages

Publishing is configured in [projects/zitadel-pgrst-angular/package.json](projects/zitadel-pgrst-angular/package.json) via `publishConfig.registry = https://npm.pkg.github.com`; the repository-level [`.npmrc`](.npmrc) maps the `@heimvio` scope to that registry. To publish a new version:

```bash
# bump version in projects/zitadel-pgrst-angular/package.json
npm run build:lib
cd dist/zitadel-pgrst-angular
# expects ~/.npmrc with: //npm.pkg.github.com/:_authToken=<GitHub token with write:packages>
npm publish
```

Consumers add `@heimvio:registry=https://npm.pkg.github.com` to their own `.npmrc` (per project or per user) plus a token with `read:packages` (see Quickstart step 1). Use the **GitHub Packages npm registry** (not the OCI/`ghcr.io` Docker registry).

This package was previously published as `@proxvex/zitadel-pgrst-auth-angular`; the API is unchanged apart from the additions listed above, so migrating means replacing the import prefix.

## Packaging for proxvex deployment

[`examples/packaging/pack-for-proxvex.sh`](examples/packaging/pack-for-proxvex.sh) bundles any app built on this library into a self-contained tarball: built SPA + base SQL + app SQL + bootstrap script.

```bash
examples/packaging/pack-for-proxvex.sh \
  --app-dir   examples/products/web \
  --bootstrap examples/products/bootstrap/bootstrap.sh \
  --app-sql   examples/products/db \
  --out       products
# -> dist/products-proxvex.tgz
```

proxvex consumes the tarball: extract `web/` to nginx, run `bootstrap/bootstrap.sh` once.

## Architecture in one paragraph

Identity lives in **Zitadel** (orgs, users, OIDC, MFA). On every request, **PostgREST** verifies the Zitadel JWT (RS256 via JWKS) and sets `request.jwt.claims`. The DB has only two anchor tables — `auth.organizations` and `auth.users` — keyed by the Zitadel ids; they are mirrored just-in-time on first login by `auth.ensure_principal()`. Roles live in `auth.user_roles` as free strings (no claim-side mapping, no Zitadel actions). App tables follow the pattern `org_id uuid NOT NULL DEFAULT auth.org_id()` plus RLS policies gated by `auth.has_role(...)`. **Provisioning** (new users, role assignment) uses the *caller's own OIDC token* against the Zitadel management API — no service account, no backend — and a small set of SECURITY DEFINER RPCs to mirror the change in `auth.users` / `auth.user_roles`. The boundary between core and app is documented in [EXTENDING.md](EXTENDING.md).

## Where things live

| What                    | Path                                                              |
| ----------------------- | ----------------------------------------------------------------- |
| Library sources         | [`projects/zitadel-pgrst-angular/`](projects/zitadel-pgrst-angular/) |
| SQL schema (assets)     | [`projects/zitadel-pgrst-angular/assets/db/`](projects/zitadel-pgrst-angular/assets/db/) |
| Example app             | [`examples/products/`](examples/products/)                        |
| Packaging script        | [`examples/packaging/pack-for-proxvex.sh`](examples/packaging/pack-for-proxvex.sh) |
| Headless verification   | [`verify.sh`](verify.sh)                                          |
| Extending conventions   | [`EXTENDING.md`](EXTENDING.md)                                    |

## Verification

Two layers, both runnable against the same `docker compose up -d` stack.

**1. Headless backend** — [`verify.sh`](verify.sh) drives the full chain (real Zitadel JWT → PostgREST JWKS verify → JIT → RLS → provisioning RPCs) with `curl`. No browser, no UI, ~10 seconds.

```bash
docker run --rm --network zitadel-pgrst-angular_default \
  -v zitadel-pgrst-angular_zbootstrap:/bootstrap:ro \
  -v "$PWD/verify.sh:/verify.sh:ro" alpine:3.20 sh /verify.sh
```

**2. Browser E2E** — Playwright drives the real OIDC flow (Zitadel hosted login UI), tenant isolation, and the provisioning admin UI. See [`e2e/README.md`](e2e/README.md) for the spec catalog and [`scripts/e2e.sh`](scripts/e2e.sh) for the workflow wrapper.

```bash
scripts/e2e.sh dev    # one-off: builds lib + app, starts stack in dev mode, waits for bootstrap
scripts/e2e.sh test   # runs the suite (8 specs, ~1 min)
```

For tight iteration without re-bootstrapping Zitadel:

```bash
scripts/e2e.sh iter      # rebuilds lib + app on host, runs tests (web is bind-mounted)
scripts/e2e.sh reapply   # re-applies 01_auth_schema.sql + 02_provisioning.sql into the live DB
                         # (works because every fn uses CREATE OR REPLACE)
scripts/e2e.sh reset     # destructive: down -v + up (only when you change anchor schema/DDL)
```

Two modes:

| Mode    | Web container             | Use when                                          |
| ------- | ------------------------- | ------------------------------------------------- |
| `up`    | built inside Docker       | mirroring production / CI                         |
| `dev`   | bind-mount on host `dist/`| iterating locally — changes show up after `iter`  |

The E2E suite is the safety net for library changes — if it stays green, your `auth` + `provisioning` building blocks survive the round-trip Zitadel → SPA → PostgREST → RLS.
