# zitadel-pgrst-auth

Generischer, wiederverwendbarer Baustein: **Zitadel-Login → PostgREST/Postgres
mit Mandanten-RLS** — ohne Zitadel-Action, ohne nginx-Lua, ohne HMAC, ohne
gemeinsames JWT-Secret. PostgREST verifiziert das Zitadel-JWT direkt per
**JWKS/RS256**; Org+User entstehen **Just-in-Time** in der DB; Autorisierung
rein DB-seitig über `auth.*` + `auth.user_roles`.

## Reproduzierbares Deliverable

```bash
docker compose up
```

Dann <http://localhost:8089> öffnen und mit einem der Demo-User einloggen:

| Login | Passwort | Rolle |
|---|---|---|
| `alice@a.demo` | `Demo1!Pass` | Firma A · staff |
| `bob@a.demo`   | `Demo1!Pass` | Firma A · customer |
| `carol@b.demo` | `Demo1!Pass` | Firma B · staff |
| `dave@b.demo`  | `Demo1!Pass` | Firma B · customer |

Erwartung: Firma-A-User sehen **nur** Firma-A-Produkte; `staff` darf anlegen,
`customer` nicht (403). Zweiter `docker compose up` ist idempotent.

## Bausteine

- **`auth/` — generischer KERN** (Single Source of Truth, das was eine App
  wiederverwendet / proxvex-`331` einspielt):
  - `auth/00_roles.sql` — PostgREST-Rollen (`web_user`/`authenticator`).
  - `auth/01_auth_schema.sql` — `auth.organizations/users/user_roles`,
    `auth.ensure_principal()` (JIT), STABLE-Accessoren, `whoami()`,
    `public.ensure_principal()`.
- **`example/` — Beispiel-App** (gehört NICHT zum Kern):
  - `example/02_products.sql` — Produktliste + RLS (Muster
    `org_id DEFAULT auth.org_id()`).
- `bootstrap/bootstrap.sh` — idempotenter Zitadel-Bootstrap + Seed.
- `login/` — minimaler statischer OIDC-PKCE-Client.

## Headless-Verifikation

`verify.sh` beweist die komplette Kette ohne Browser (echtes Zitadel-JWT via
client_credentials-Maschinenuser → PostgREST JWKS-Verify → JIT → RLS):

```bash
docker run --rm --network zitadel-pgrst-auth_default \
  -v zitadel-pgrst-auth_zbootstrap:/bootstrap:ro \
  -v "$PWD/verify.sh:/verify.sh:ro" alpine:3.20 sh /verify.sh
```

Erwartet: Org-Isolation (svc-a nur Firma-A-, svc-b nur Firma-B-Produkte),
Default-Deny ohne Rolle, `staff` POST → 201, `customer` POST → abgelehnt.

## Befunde aus Phase A (Input für Phase B / EXTENDING)

- **Org-ID-Claim** (Schritt 0, empirisch bestätigt):
  `urn:zitadel:iam:user:resourceowner:id` (Scope
  `urn:zitadel:iam:user:resourceowner`); `urn:zitadel:iam:org:id` ist leer.
- **PostgREST GET = read-only Tx:** `PGRST_DB_PRE_REQUEST` darf dort nicht
  schreiben → `auth.ensure_principal()` ist im read-only-Fall ein No-op; der
  Login-Client ruft einmalig `POST /rpc/ensure_principal` (schreibbar).
- **org-scoped Tabellen:** `org_id uuid NOT NULL DEFAULT auth.org_id()` →
  Clients senden kein `org_id`, RLS `WITH CHECK` bleibt zwingend. Kernmuster.
- **Zitadel:** Instanz-Auflösung per `Host`-Header (intern `Host: localhost`);
  FirstInstance-PAT braucht beschreibbares Volume (Demo: Zitadel als root).
- **PostgREST** prüft kein `iss`; `aud` ungeprüft (Demo) — Prod: `PGRST_JWT_AUD`.

Die Grenze Kern ↔ App wird in Phase B final gezogen (`EXTENDING.md`).
