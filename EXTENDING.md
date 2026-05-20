# EXTENDING — building an app on the base

The **core** is two SQL bundles + an Angular library with two entrypoints:

```
projects/zitadel-pgrst-auth-angular/
  assets/db/
    00_roles.sql            # PostgREST roles
    01_auth_schema.sql      # auth.organizations / users / user_roles + JIT + accessors
    02_provisioning.sql     # provision_user / assign_role / list_org_users / …
  auth/                     # provideAuth, AuthService, authGuard, roleGuard, …
  provisioning/             # provideProvisioning, ProvisioningService, admin UI components, routes
```

It knows only Zitadel **org** and **user**; roles are assigned **in the DB** in `auth.user_roles` (role-name-agnostic). Everything under `examples/` is example, not core.

This guide is explained against the **shipped, runnable example** `examples/products/`.

## Contract (what the core guarantees)

- `auth.org_id()` → caller's internal org UUID (from the JWKS-verified Zitadel JWT; org claim `urn:zitadel:iam:user:resourceowner:id`).
- `auth.user_id()` → internal user UUID; `auth.has_role(text)` / `auth.roles()` → DB-side roles from `auth.user_roles`.
- `public.whoami()` → `{user_id, org_id, roles}` (frontend profile source).
- `public.ensure_principal()` (JIT) creates org+user idempotently, assigns **no** roles → safe default-deny.
- `public.provision_user(zitadel_sub, email, roles[])` → ORG_OWNER-gated, scoped to caller's org. Plus `public.assign_role`, `public.revoke_role`, `public.list_org_users`, `public.remove_user`, `public.provision_org`.

## 1. DB: org-scoped table — like `examples/products/db/02_products.sql`

Apply this pattern 1:1 to your own tables:

```sql
CREATE TABLE public.products (
  id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL DEFAULT auth.org_id()       -- client NEVER sends org_id
         REFERENCES auth.organizations(id) ON DELETE CASCADE,
  name   text NOT NULL,
  price  numeric(10,2) NOT NULL
);
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

CREATE POLICY products_read ON public.products FOR SELECT
  USING (org_id = auth.org_id()
         AND (auth.has_role('customer') OR auth.has_role('staff')));

CREATE POLICY products_write ON public.products FOR ALL
  USING      (org_id = auth.org_id() AND auth.has_role('staff'))
  WITH CHECK (org_id = auth.org_id() AND auth.has_role('staff'));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.products TO web_user;
```

`org_id DEFAULT auth.org_id()` + `WITH CHECK` ⇒ tenant isolation without the client ever sending `org_id`. Role names are **the app's choice** (here `customer`/`staff`; in nebenkosten e.g. `tenant`/`org_owner`).

Apply order: core SQL first (00 → 01 → 02), then app SQL.

## 2. PostgREST

**Development (`docker-compose.yml`, `postgrest` service):** explicit env

```
PGRST_DB_ANON_ROLE=web_user
PGRST_DB_PRE_REQUEST=auth.ensure_principal
PGRST_JWT_SECRET=@/shared/jwks.json     # Zitadel /oauth/v2/keys (RS256)
# production additionally: PGRST_JWT_AUD=<aud>
```

**Production (proxvex PostgREST application):** set `db_anon_role=web_user`; the remaining variables (`PGRST_DB_PRE_REQUEST`, `PGRST_JWT_SECRET`, optional `PGRST_JWT_AUD`) are defaults in the proxvex PostgREST application.

## 3. Provisioning — let an ORG_OWNER create users in their own org

The core ships:

- **SQL** (`02_provisioning.sql`): `auth.provision_org / provision_user / assign_role / revoke_role / list_org_users / remove_user`, all SECURITY DEFINER and gated by `auth.has_role(auth.org_admin_role())` (default `'org_owner'`; configurable per app via `CREATE OR REPLACE FUNCTION auth.org_admin_role()`).
- **Angular** (`/provisioning` entrypoint): `ZitadelAdminService` (Zitadel mgmt-API via the caller's own OIDC token — no backend, no service account), `ProvisioningService` (orchestrates Zitadel-then-DB, idempotent via UNIQUE on `zitadel_sub`/`zitadel_org_id`), and a complete admin UI module with ready-made routes.

### 3.1 Wire it in your `main.ts`

```ts
import { provideAuth } from '@proxvex/zitadel-pgrst-auth-angular/auth';
import { provideProvisioning, provisioningRoutes } from '@proxvex/zitadel-pgrst-auth-angular/provisioning';

bootstrapApplication(AppComponent, {
  providers: [
    provideRouter([
      ...yourAppRoutes,
      { path: 'admin', children: provisioningRoutes() }
    ]),
    provideAuth(),
    provideProvisioning({
      rolesCatalog: ['org_owner', 'tenant', 'meter_reader']   // your app's roles
    })
  ]
});
```

`provisioningRoutes()` returns guarded routes for `/admin/users` (`org_owner` only) and `/admin/orgs` (`iam_org_owner` only). Mount them under any base path.

### 3.2 SPA OIDC scope — REQUIRED for the Zitadel mgmt-API to accept the caller's token

The provisioning client uses the *logged-in admin's own access token* to call Zitadel. The token must therefore carry the Zitadel API audience:

```json
// config.json
"oidc": {
  ...
  "scope": "openid profile email urn:zitadel:iam:user:resourceowner urn:zitadel:iam:org:project:id:zitadel:aud"
}
```

Without that last (reserved) scope, Zitadel will reject mgmt-API calls. Also ensure Zitadel CORS allows your SPA origin.

### 3.3 Privileged paths — reverse-proxy scope

`/v2/organizations` (creating new orgs) is an **instance-wide** mgmt-API path; the caller must have IAM-level admin in Zitadel. In production, restrict that path to LAN at your nginx layer. `/v2/users/*` and `/management/v1/orgs/me/members` are org-scoped (delegated admin); these are safe to expose to the SPA.

### 3.4 First-org-admin bootstrap

When `iam_org_owner` creates a new org via `<base-org-list>` or `ProvisioningService.createOrg()`, the service:

1. Creates the Zitadel org.
2. Mirrors it in `auth.organizations` via `provision_org`.
3. If `firstOwner.email` is given: creates a human user in that org **and** calls `addOrgManager` with Zitadel-role `ORG_OWNER`. After the new owner logs in, the JIT mirror creates their `auth.users` row; you still need to assign the app-level `org_owner` role in `auth.user_roles` (e.g. via a one-time seed in your bootstrap script, or by extending `createOrg` in a custom service to also call `provision_user`).

### 3.5 Customising the admin role name

```sql
-- in your app's SQL
CREATE OR REPLACE FUNCTION auth.org_admin_role() RETURNS text
  LANGUAGE sql IMMUTABLE AS $$ SELECT 'hausverwalter'::text $$;
```

```ts
// in provideProvisioning
provideProvisioning({
  rolesCatalog: ['hausverwalter', 'tenant', ...],
  orgAdminRole: 'hausverwalter'   // matches the SQL override
})
```

## 4. Manual role assignment (one-off / seed)

For one-off seeds outside the provisioning RPCs (e.g. the very first IAM admin), insert directly:

```sql
INSERT INTO auth.user_roles (user_id, role)
  SELECT id, 'iam_org_owner' FROM auth.users WHERE zitadel_sub = '<sub>';
```

This is the same path the example bootstrap takes for the demo users.

## 5. Angular — using individual building blocks

```ts
// component
auth: AuthService = inject(AuthService);
auth.profile();            // { user_id, org_id, roles } from whoami
auth.hasRole('staff');     // UI gating (server RLS remains the enforcement)
auth.claims();             // raw OIDC id-token claims (for callerZitadelOrgId etc.)

// drop-in admin UI
@Component({
  imports: [OrgUsersListComponent],
  template: `<base-org-users-list />`   // uses the app's ProvisioningConfig
})
```

`provideAuth()` does, via `APP_INITIALIZER`: load `config.json` → OIDC init → after login call `POST /rpc/ensure_principal` once (writable tx, JIT) → `whoami`. GET runs read-only; `ensure_principal` is deliberately a no-op there.

## App boundaries / responsibilities

- **Role-assignment authority:** the core stores; provisioning RPCs enforce org scoping; the *first* IAM admin is seeded by the app/deploy step. Without assignment → default-deny.
- **Zitadel setup** (org/user/OIDC app, access token type JWT, CORS for the SPA origin, audience scope): app/deploy concern — example: `examples/products/bootstrap/`.
- **Reverse proxy** (network-restrict `/v2/organizations`, terminate TLS, host static SPA + `config.json`): the app's own concern.
- **No backend service account for provisioning** — the SPA acts with the admin's own delegated rights. If you ever do need a backend (e.g. for cron-driven provisioning), implement it in your app, not in the core.
