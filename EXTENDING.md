# EXTENDING — eine App auf der Basis aufsetzen

Der **Kern** ist ausschließlich `auth/` (`00_roles.sql` + `01_auth_schema.sql`).
Er kennt nur Zitadel-**Org** und **User**; Rollen werden **DB-seitig** in
`auth.user_roles` vergeben (rollennamen-agnostisch). Alles unter `example/`
ist Beispiel, nicht Kern.

## Vertrag (was der Kern garantiert)

- `auth.org_id()` → interne Org-UUID des aktuellen Aufrufers (aus dem
  JWKS-verifizierten Zitadel-JWT; Org-Claim
  `urn:zitadel:iam:user:resourceowner:id`).
- `auth.user_id()` → interne User-UUID. `auth.roles()` / `auth.has_role(text)`
  → DB-seitige Rollen aus `auth.user_roles`.
- `public.whoami()` → `{user_id, org_id, roles}` (Frontend-Profil-Quelle).
- JIT: `public.ensure_principal()` legt Org+User idempotent an, vergibt **keine**
  Rollen (sicherer Default-Deny).

## So baut eine App darauf auf

1. **Kern einspielen** (`auth/00_roles.sql`, dann `auth/01_auth_schema.sql`).
   In Produktion erledigt das das proxvex-Template `331-provision-auth-rls`.

2. **Org-scoped Tabelle** anlegen — Kernmuster:

   ```sql
   CREATE TABLE app.things (
     id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
     org_id uuid NOT NULL DEFAULT auth.org_id()
            REFERENCES auth.organizations(id) ON DELETE CASCADE,
     ...
   );
   ALTER TABLE app.things ENABLE ROW LEVEL SECURITY;

   -- Lesen: eigene Org + (mind.) eine App-Rolle
   CREATE POLICY things_read ON app.things FOR SELECT
     USING (org_id = auth.org_id() AND auth.has_role('<lese-rolle>'));

   -- Schreiben: eigene Org + Schreib-Rolle (USING und WITH CHECK!)
   CREATE POLICY things_write ON app.things FOR ALL
     USING      (org_id = auth.org_id() AND auth.has_role('<schreib-rolle>'))
     WITH CHECK (org_id = auth.org_id() AND auth.has_role('<schreib-rolle>'));

   GRANT SELECT, INSERT, UPDATE, DELETE ON app.things TO web_user;
   ```

   `org_id DEFAULT auth.org_id()` ⇒ Clients senden **nie** `org_id`;
   `WITH CHECK` erzwingt es trotzdem. Rollennamen sind **App-Sache**
   (z. B. `customer`/`staff`, in nebenkosten `tenant`/`hausverwalter`).

3. **PostgREST**: `PGRST_DB_PRE_REQUEST=auth.ensure_principal`,
   `PGRST_JWT_SECRET=@<jwks-datei>` (Zitadel `/oauth/v2/keys`),
   `PGRST_DB_ANON_ROLE=web_user`. In Produktion: `PGRST_JWT_AUD` setzen.

4. **Rollen vergeben** (App-Admin, NICHT der Kern):
   `INSERT INTO auth.user_roles(user_id, role) SELECT id,'<rolle>'
    FROM auth.users WHERE zitadel_sub = '<zitadel-user-id>';`
   Wer das darf, definiert die App per eigener Policy auf `auth.user_roles`.

5. **Client**: nach OIDC-Login **einmal** `POST /rpc/ensure_principal`
   (schreibbare Tx → JIT-Spiegel), danach normal arbeiten. GET läuft in
   read-only-Tx; `ensure_principal` ist dort bewusst No-op.

## Grenzen / Pflichten der App

- Rollen-Vergabe-Autorität: der Kern speichert nur. Ohne App-Policy auf
  `auth.user_roles` kann niemand Rollen setzen → alles Default-Deny.
- Zitadel-Setup (Org/User/OIDC-App, Token-Typ JWT) ist App-/Deploy-Sache
  (Beispiel: `bootstrap/`; Produktion: proxvex zitadel-App + `331`).
- Kein nginx-Baustein im Kern — Reverse-Proxy/Routing macht die App selbst.
