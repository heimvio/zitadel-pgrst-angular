# @proxvex/zitadel-pgrst-auth-angular

Two secondary entrypoints:

- `@proxvex/zitadel-pgrst-auth-angular/auth` — OIDC-PKCE login, JIT principal mirror, `whoami` profile, `authInterceptor`, `authGuard` / `roleGuard`, `provideAuth()`.
- `@proxvex/zitadel-pgrst-auth-angular/provisioning` — Zitadel management API client (caller-token, no backend), `ProvisioningService`, admin UI components (`<base-org-list>`, `<base-org-users-list>`, `<base-add-user-dialog>`, `<base-role-picker>`, `<base-machine-user-form>`), `provideProvisioning()`, ready-made routes.

SQL schema files ship as assets under `assets/db/`:

- `00_roles.sql` — `web_user`/`authenticator` roles.
- `01_auth_schema.sql` — `auth.organizations`/`users`/`user_roles` + JIT + accessors + `whoami`.
- `02_provisioning.sql` — RPCs for org-scoped user/role provisioning (`provision_user`, `assign_role`, `list_org_users`, …).

See the repo README for setup, quickstart, and the proxvex packaging script.
