# Example: products

A minimal, runnable app on top of the generic core (`auth/` + `angular-auth/`):
a **per-organization product list** with two app-defined roles —
`customer` (read) and `staff` (read + create). It demonstrates tenant
isolation and role gating end to end.

This is exactly what the repository-root `docker compose` brings up. The
compose file and `.env` live at the repo root; the base bootstrap that
creates the DB schema is at [`../../bootstrap/`](../../bootstrap/); this
folder holds the
example-specific parts:

- `db/02_products.sql` — the `products` table + RLS policies.
- `bootstrap/bootstrap.sh` — idempotent Zitadel + DB seed; writes the app's
  runtime `config.json`.

## Start

Prerequisite: Docker (with the Compose plugin). From the **repository root**:

```bash
docker compose up
```

First start takes **~1–2 minutes** (Zitadel initialises its database, then the
bootstrap creates the orgs/users/app and seeds the data). A second
`docker compose up` is idempotent.

**Knowing when it's ready:** the `bootstrap` service runs last — the web app
and PostgREST only start after it succeeds. So:

```bash
docker compose logs -f bootstrap     # ready when you see: bootstrap: done.
```

(Re-run with existing volumes prints `already initialised … only refreshed
JWKS` instead — also ready.) Equivalently, <http://localhost:8089> only
answers once the stack is up.

Then open <http://localhost:8089> and log in with a demo user:

| Login          | Password     | Role                 |
| -------------- | ------------ | -------------------- |
| `alice@a.demo` | `Demo1!Pass` | Company A · staff    |
| `bob@a.demo`   | `Demo1!Pass` | Company A · customer |
| `carol@b.demo` | `Demo1!Pass` | Company B · staff    |
| `dave@b.demo`  | `Demo1!Pass` | Company B · customer |

Expected:

- Company-A users see **only** Company-A products, Company-B users only
  Company-B products (tenant isolation via `auth.org_id()`).
- `staff` can create a product; `customer` cannot — the request is denied
  server-side by RLS (HTTP 4xx).

### Rebuilding after changes

`docker compose up` reuses the already-built `web` image. After editing the
Angular sources (`examples/products/web/`, `angular-auth/`) rebuild it:

```bash
docker compose up -d --build web      # or: docker compose up --build
```

DB changes under `auth/` or `examples/products/db/` only run on an empty
volume — re-run with `docker compose down -v && docker compose up`. The same
applies to `bootstrap/` (idempotent via `bootstrap.done`).

Default ports (override in the repo-root `.env`):

| Service     | URL                     |
| ----------- | ----------------------- |
| Angular app | <http://localhost:8089> |
| PostgREST   | <http://localhost:3001> |
| Zitadel     | <http://localhost:8090> |
| Postgres    | `localhost:55433`       |

## Headless verification (no browser)

Proves the full chain with a real Zitadel JWT (machine user via
client_credentials → PostgREST JWKS verify → JIT → RLS):

```bash
docker run --rm --network zitadel-pgrst-angular_default \
  -v zitadel-pgrst-angular_zbootstrap:/bootstrap:ro \
  -v "$PWD/verify.sh:/verify.sh:ro" alpine:3.20 sh /verify.sh
```

Expected: org isolation, default-deny without a role, `staff` POST → 201,
`customer` POST → denied.

## Teardown

```bash
docker compose down -v     # also removes the volumes (fresh next start)
```

## How it works / building your own

See [../../EXTENDING.md](../../EXTENDING.md) — this example is the reference
copy template (also for the later nebenkosten migration).
