# EXTENDING — building an app on the base

The **core** is `auth/` (`00_roles.sql` + `01_auth_schema.sql`) plus the
generic Angular building block `angular-auth/`. It knows only Zitadel **org**
and **user**; roles are assigned **in the DB** in `auth.user_roles`
(role-name-agnostic). Everything under `examples/` is example, not core.

This guide is explained against the **shipped, runnable example**
`examples/products/` — it is the reference/copy template (also for the later
nebenkosten migration).

## Contract (what the core guarantees)

- `auth.org_id()` → caller's internal org UUID (from the JWKS-verified
  Zitadel JWT; org claim `urn:zitadel:iam:user:resourceowner:id`).
- `auth.user_id()` → internal user UUID; `auth.has_role(text)` / `auth.roles()`
  → DB-side roles from `auth.user_roles`.
- `public.whoami()` → `{user_id, org_id, roles}` (frontend profile source).
- `public.ensure_principal()` (JIT) creates org+user idempotently, assigns
  **no** roles → safe default-deny.

## 1. DB: org-scoped table — like `examples/products/db/02_products.sql`

Apply exactly this pattern (1:1 from the example) to your own tables:

```sql
CREATE TABLE public.products (
  id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL DEFAULT auth.org_id()       -- client NEVER sends org_id
         REFERENCES auth.organizations(id) ON DELETE CASCADE,
  name   text NOT NULL,
  price  numeric(10,2) NOT NULL
);
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

-- Read: own org, visible to customer OR staff
CREATE POLICY products_read ON public.products FOR SELECT
  USING (org_id = auth.org_id()
         AND (auth.has_role('customer') OR auth.has_role('staff')));

-- Write: staff only, own org (USING + WITH CHECK!)
CREATE POLICY products_write ON public.products FOR ALL
  USING      (org_id = auth.org_id() AND auth.has_role('staff'))
  WITH CHECK (org_id = auth.org_id() AND auth.has_role('staff'));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.products TO web_user;
```

`org_id DEFAULT auth.org_id()` + `WITH CHECK` ⇒ tenant isolation without the
client ever sending `org_id`. Role names are **the app's choice** (here
`customer`/`staff`; in nebenkosten e.g. `tenant`/`hausverwalter`).

Apply order: core first, then app SQL — see `init.sh`
(`auth/00_roles.sql` → `auth/01_auth_schema.sql` → `examples/products/db/*`).
In production the proxvex template `331-provision-auth-rls` installs the core.

## 2. PostgREST

**Development (`docker-compose.yml`, `postgrest` service):** explicit env

```
PGRST_DB_ANON_ROLE=web_user
PGRST_DB_PRE_REQUEST=auth.ensure_principal
PGRST_JWT_SECRET=@/shared/jwks.json     # Zitadel /oauth/v2/keys (RS256)
# production additionally: PGRST_JWT_AUD=<aud>
```

**Production (proxvex PostgREST application):** the proxvex model —

- `db_anon_role` is a **parameter** of the proxvex PostgREST app
  (default `web_anon`; PostgREST only starts if the role exists).
  For this base: set **`db_anon_role=web_user`** — the role is created by
  `auth/00_roles.sql` (in prod via the `331-provision-auth-rls` template).
- `db_schemas` (parameter) stays `public`.
- The remaining variables (`PGRST_DB_PRE_REQUEST=auth.ensure_principal`,
  `PGRST_JWT_SECRET=@<jwks>`, optionally `PGRST_JWT_ROLE_CLAIM_KEY`,
  `PGRST_JWT_AUD`) belong as **defaults in the proxvex PostgREST app**
  (compose env + documented in its `application.md`, *Authentication*
  section). Phase C wires this generically — consumer apps then only set
  `db_anon_role`.

## 3. Assigning roles — like `examples/products/bootstrap/bootstrap.sh` (app admin, NOT core)

The example assigns the demo roles exactly like this:

```sql
INSERT INTO auth.user_roles (user_id, role)
  SELECT id,'staff'    FROM auth.users WHERE zitadel_sub IN ('<sub-alice>','<sub-carol>');
INSERT INTO auth.user_roles (user_id, role)
  SELECT id,'customer' FROM auth.users WHERE zitadel_sub IN ('<sub-bob>','<sub-dave>');
```

Who is allowed to do this is defined by the app via its own policy/admin on
`auth.user_roles` (the core only stores). Without assignment → default-deny.

## 4. Angular — include the generic building block `angular-auth/`

Like `examples/products/web` (the Dockerfile includes `angular-auth/` as
`src/auth/`, the app imports `./auth`):

```ts
// main.ts
bootstrapApplication(AppComponent, {
  providers: [provideRouter(routes), provideAuth()]   // from './auth'
});

// app.routes.ts — route protection, the app supplies the role names
{ path: '', component: ProductsComponent, canActivate: [authGuard] }

// component
auth = inject(AuthService);
auth.profile();            // { user_id, org_id, roles } from whoami
auth.hasRole('staff');     // UI gating (server RLS remains the enforcement)
```

`provideAuth()` does, via `APP_INITIALIZER`: load `config.json` → OIDC init →
after login call `POST /rpc/ensure_principal` **once** (writable tx, JIT) →
`whoami`. GET runs read-only; `ensure_principal` is deliberately a no-op there.

The runtime `config.json` (issuer/clientId/postgrest) is written by the
bootstrap → one build runs against any environment.

## App boundaries / responsibilities

- **Role-assignment authority:** the core only stores; without an app policy
  on `auth.user_roles` nobody can set roles → everything default-deny.
- **Zitadel setup** (org/user/OIDC app, access token type JWT): app/deploy
  concern — example: `examples/products/bootstrap/`; production: proxvex
  zitadel app + `331`.
- **No nginx in the core** — reverse proxy/routing is the app's own concern.
