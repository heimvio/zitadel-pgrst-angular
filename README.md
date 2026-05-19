# zitadel-pgrst-auth

Generic, reusable building block: **Zitadel login → PostgREST/Postgres with
tenant RLS** — no Zitadel action, no nginx-Lua, no HMAC, no shared JWT secret.
PostgREST verifies the Zitadel JWT directly via **JWKS/RS256**; org+user are
created **just-in-time** in the DB; authorization is purely DB-side via
`auth.*` + `auth.user_roles`.

## Reproducible deliverable

```bash
docker compose up
```

Then open <http://localhost:8089> and log in with one of the demo users:

| Login | Password | Role |
|---|---|---|
| `alice@a.demo` | `Demo1!Pass` | Company A · staff |
| `bob@a.demo`   | `Demo1!Pass` | Company A · customer |
| `carol@b.demo` | `Demo1!Pass` | Company B · staff |
| `dave@b.demo`  | `Demo1!Pass` | Company B · customer |

Expectation: Company-A users see **only** Company-A products; `staff` may
create, `customer` may not (403). A second `docker compose up` is idempotent.

## Building blocks

**CORE (generic, reusable — what an app / proxvex `331` installs):**

- `auth/00_roles.sql` — PostgREST roles (`web_user`/`authenticator`).
- `auth/01_auth_schema.sql` — `auth.organizations/users/user_roles`,
  `auth.ensure_principal()` (JIT), STABLE accessors, `whoami()`,
  `public.ensure_principal()`.
- `angular-auth/` — generic Angular auth building block (copy-/path-mappable
  as one unit; nebenkosten consumes exactly this): `AuthService` (OIDC-PKCE via
  angular-oauth2-oidc, JIT `ensure_principal`, whoami profile signal,
  role-name-agnostic helpers), `authInterceptor`, `authGuard`/`roleGuard`,
  `provideAuth()`. See [EXTENDING.md](EXTENDING.md).

**Example app (NOT part of the core) — `examples/products/`:**

- `examples/products/db/02_products.sql` — product list + RLS (pattern
  `org_id DEFAULT auth.org_id()`).
- `examples/products/web/` — mini Angular app on the core building block
  (login, whoami, product list, creating staff-only). The build includes
  `angular-auth/` as `src/auth/` (Dockerfile, context = repo root).
- `examples/products/bootstrap/bootstrap.sh` — idempotent Zitadel bootstrap
  + seed; writes `config.json` at runtime (issuer/clientId/postgrest) so one
  build runs against any environment. Example/deploy concern, not core.

## Headless verification

`verify.sh` proves the full chain without a browser (real Zitadel JWT via a
client_credentials machine user → PostgREST JWKS verify → JIT → RLS):

```bash
docker run --rm --network zitadel-pgrst-auth_default \
  -v zitadel-pgrst-auth_zbootstrap:/bootstrap:ro \
  -v "$PWD/verify.sh:/verify.sh:ro" alpine:3.20 sh /verify.sh
```

Expected: org isolation (svc-a only Company-A, svc-b only Company-B products),
default-deny without a role, `staff` POST → 201, `customer` POST → denied.

## Findings (input for EXTENDING)

- **Org-id claim** (empirically confirmed):
  `urn:zitadel:iam:user:resourceowner:id` (scope
  `urn:zitadel:iam:user:resourceowner`); `urn:zitadel:iam:org:id` is empty.
- **PostgREST GET = read-only tx:** `PGRST_DB_PRE_REQUEST` must not write
  there → `auth.ensure_principal()` is a no-op in the read-only case; the
  login client calls `POST /rpc/ensure_principal` once (writable).
- **org-scoped tables:** `org_id uuid NOT NULL DEFAULT auth.org_id()` →
  clients never send `org_id`, RLS `WITH CHECK` still enforces it. Core pattern.
- **Zitadel:** instance resolution via the `Host` header (internally
  `Host: localhost`); the FirstInstance PAT needs a writable volume
  (demo: Zitadel as root).
- **PostgREST** does not check `iss`; `aud` unchecked (demo) —
  production: set `PGRST_JWT_AUD`.

The core ↔ app boundary is documented in [EXTENDING.md](EXTENDING.md).
