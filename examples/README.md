# Examples

Runnable apps built on the generic core (`auth/` + `angular-auth/`).
Each example is the reference/copy template for building your own app.

- [`products/`](products/README.md) — per-organization product list with
  `customer`/`staff` roles. Full details (demo logins, expected behaviour,
  headless verification) are in its README.

## How to start

There is **no `docker-compose.yml` inside `examples/`** — by design the single
compose stack lives at the **repository root** (it wires Postgres, Zitadel, the
bootstrap, PostgREST and the example web app together). Start it from the

```bash
git clone <this-repo> zitadel-pgrst-angular
cd zitadel-pgrst-angular          # the directory that contains docker-compose.yml
docker compose up
```

(If you already have the repo: `cd` into its root — the folder with
`docker-compose.yml` — and run `docker compose up`.)

seeds orgs/users/products). A second `docker compose up` is idempotent.

Then open <http://localhost:8089> and log in with a demo user, e.g.
`alice@a.demo` / `Demo1!Pass` (Company A · staff). Full login table and the
expected tenant-isolation / role-gating behaviour:
[products/README.md](products/README.md).

Teardown:

```bash
docker compose down -v
```

The core ↔ app contract is documented in [../EXTENDING.md](../EXTENDING.md).
