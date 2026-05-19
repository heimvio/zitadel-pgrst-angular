# EXTENDING — eine App auf der Basis aufsetzen

Der **Kern** ist `auth/` (`00_roles.sql` + `01_auth_schema.sql`) plus der
generische Angular-Baustein `angular-auth/`. Er kennt nur Zitadel-**Org** und
**User**; Rollen werden **DB-seitig** in `auth.user_roles` vergeben
(rollennamen-agnostisch). Alles unter `examples/` ist Beispiel, nicht Kern.

Diese Anleitung erklärt am **mitgelieferten, lauffähigen Beispiel**
`examples/products/` — es ist die Referenz/Kopiervorlage (auch für die spätere
nebenkosten-Migration).

## Vertrag (was der Kern garantiert)

- `auth.org_id()` → interne Org-UUID des Aufrufers (aus dem JWKS-verifizierten
  Zitadel-JWT; Org-Claim `urn:zitadel:iam:user:resourceowner:id`).
- `auth.user_id()` → interne User-UUID; `auth.has_role(text)` / `auth.roles()`
  → DB-seitige Rollen aus `auth.user_roles`.
- `public.whoami()` → `{user_id, org_id, roles}` (Frontend-Profil-Quelle).
- `public.ensure_principal()` (JIT) legt Org+User idempotent an, vergibt
  **keine** Rollen → sicherer Default-Deny.

## 1. DB: org-scoped Tabelle — wie `examples/products/db/02_products.sql`

Genau dieses Muster (1:1 aus dem Beispiel) auf eigene Tabellen anwenden:

```sql
CREATE TABLE public.products (
  id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL DEFAULT auth.org_id()       -- Client sendet NIE org_id
         REFERENCES auth.organizations(id) ON DELETE CASCADE,
  name   text NOT NULL,
  price  numeric(10,2) NOT NULL
);
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

-- Lesen: eigene Org, sichtbar für customer ODER staff
CREATE POLICY products_read ON public.products FOR SELECT
  USING (org_id = auth.org_id()
         AND (auth.has_role('customer') OR auth.has_role('staff')));

-- Schreiben: nur staff, eigene Org (USING + WITH CHECK!)
CREATE POLICY products_write ON public.products FOR ALL
  USING      (org_id = auth.org_id() AND auth.has_role('staff'))
  WITH CHECK (org_id = auth.org_id() AND auth.has_role('staff'));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.products TO web_user;
```

`org_id DEFAULT auth.org_id()` + `WITH CHECK` ⇒ Mandantentrennung ohne dass der
Client je `org_id` sendet. Rollennamen sind **App-Sache** (hier
`customer`/`staff`; in nebenkosten z. B. `tenant`/`hausverwalter`).

Einspielreihenfolge: Kern zuerst, dann App-SQL — siehe `init.sh`
(`auth/00_roles.sql` → `auth/01_auth_schema.sql` → `examples/products/db/*`).
In Produktion spielt das proxvex-Template `331-provision-auth-rls` den Kern ein.

## 2. PostgREST

**Entwicklung (`docker-compose.yml`, `postgrest`-Service):** explizite Envs

```
PGRST_DB_ANON_ROLE=web_user
PGRST_DB_PRE_REQUEST=auth.ensure_principal
PGRST_JWT_SECRET=@/shared/jwks.json     # Zitadel /oauth/v2/keys (RS256)
# Produktion zusätzlich: PGRST_JWT_AUD=<aud>
```

**Produktion (proxvex PostgREST-Application):** Das Modell von proxvex —

- `db_anon_role` ist ein **Parameter** der proxvex-PostgREST-App
  (Default `web_anon`; PostgREST startet nur, wenn die Rolle existiert).
  Für die Basis: **`db_anon_role=web_user`** setzen — die Rolle legt
  `auth/00_roles.sql` an (in Prod via Template `331-provision-auth-rls`).
- `db_schemas` (Parameter) bleibt `public`.
- Die übrigen Variablen (`PGRST_DB_PRE_REQUEST=auth.ensure_principal`,
  `PGRST_JWT_SECRET=@<jwks>`, ggf. `PGRST_JWT_ROLE_CLAIM_KEY`,
  `PGRST_JWT_AUD`) gehören als **Defaults in die proxvex-PostgREST-App**
  (Compose-Env + dokumentiert in deren `application.md`, Abschnitt
  *Authentication*). Das verdrahtet **Phase C** generisch — Konsument-Apps
  setzen dann nur noch `db_anon_role`.

## 3. Rollen vergeben — wie `examples/products/bootstrap/bootstrap.sh` (App-Admin, NICHT Kern)

Das Beispiel weist die Demo-Rollen genau so zu:

```sql
INSERT INTO auth.user_roles (user_id, role)
  SELECT id,'staff'    FROM auth.users WHERE zitadel_sub IN ('<sub-alice>','<sub-carol>');
INSERT INTO auth.user_roles (user_id, role)
  SELECT id,'customer' FROM auth.users WHERE zitadel_sub IN ('<sub-bob>','<sub-dave>');
````

Wer das darf, definiert die App per eigener Policy/Admin auf `auth.user_roles`
(der Kern speichert nur). Ohne Zuweisung → Default-Deny.

## 4. Angular — generischen Baustein `angular-auth/` einbinden

Wie `examples/products/web` (Dockerfile bindet `angular-auth/` als `src/auth/`
ein, App importiert `./auth`):

```ts
// main.ts
bootstrapApplication(AppComponent, {
  providers: [provideRouter(routes), provideAuth()]   // aus './auth'
});

// app.routes.ts — Routenschutz, App liefert die Rollennamen
{ path: '', component: ProductsComponent, canActivate: [authGuard] }

// Komponente
auth = inject(AuthService);
auth.profile();            // { user_id, org_id, roles } aus whoami
auth.hasRole('staff');     // UI-Gating (Server-RLS bleibt die Durchsetzung)
```

`provideAuth()` macht via `APP_INITIALIZER`: `config.json` laden → OIDC-Init →
nach Login **einmal** `POST /rpc/ensure_principal` (schreibbare Tx, JIT) →
`whoami`. GET läuft read-only; `ensure_principal` ist dort bewusst No-op.

Runtime-`config.json` (issuer/clientId/postgrest) schreibt der Bootstrap →
ein Build läuft gegen jede Umgebung.

## Grenzen / Pflichten der App

- **Rollen-Vergabe-Autorität:** Kern speichert nur; ohne App-Policy auf
  `auth.user_roles` kann niemand Rollen setzen → alles Default-Deny.
- **Zitadel-Setup** (Org/User/OIDC-App, Access-Token-Typ JWT): App-/Deploy-Sache
  — Beispiel: `examples/products/bootstrap/`; Produktion: proxvex
  zitadel-App + `331`.
- **Kein nginx im Kern** — Reverse-Proxy/Routing macht die App selbst.
