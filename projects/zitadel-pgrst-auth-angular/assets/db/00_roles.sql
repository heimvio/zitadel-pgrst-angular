-- ============================================================================
-- 00_roles.sql — PostgREST role model (core, generic)
-- ----------------------------------------------------------------------------
-- Deliberately minimal: ONE effective role `web_user`. PostgREST connects as
-- login role `authenticator` and uses `web_user` as the DB anon role for every
-- request. There is NO role claim and NO Zitadel action — all authorization
-- runs through RLS + auth.* (roles assigned in the DB in auth.user_roles).
-- "logged in vs. not" follows from the (JWKS-verified) JWT: without valid
-- claims auth.* returns NULL -> RLS denies (default-deny).
--
-- The login role's password is passed as the psql variable :authpw (set by
-- the orchestrator init.sh via -v). Idempotent.
-- ============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'web_user') THEN
    CREATE ROLE web_user NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator NOINHERIT LOGIN;
  END IF;
END$$;

-- Set the password (idempotent; source = environment variable)
SELECT format('ALTER ROLE authenticator PASSWORD %L', :'authpw')
\gexec

GRANT web_user TO authenticator;
GRANT USAGE ON SCHEMA public TO web_user;
