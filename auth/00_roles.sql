-- ============================================================================
-- 00_roles.sql — PostgREST-Rollenmodell (Basis, generisch)
-- ----------------------------------------------------------------------------
-- Bewusst minimal: EINE effektive Rolle `web_user`. PostgREST verbindet als
-- Login-Rolle `authenticator` und nutzt `web_user` als DB-Anon-Rolle für jeden
-- Request. Es gibt KEINEN Rollen-Claim und KEINE Zitadel-Action — die gesamte
-- Autorisierung läuft über RLS + auth.* (DB-seitig vergebene Rollen in
-- auth.user_roles). Unterscheidung "eingeloggt vs. nicht" ergibt sich aus dem
-- (per JWKS verifizierten) JWT: ohne gültige Claims liefern auth.* NULL ->
-- RLS verweigert (Default-Deny).
--
-- Passwort der Login-Rolle kommt als psql-Variable :authpw (vom Orchestrator
-- init.sh per -v gesetzt). Idempotent.
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

-- Passwort setzen (idempotent; Quelle = Umgebungsvariable)
SELECT format('ALTER ROLE authenticator PASSWORD %L', :'authpw')
\gexec

GRANT web_user TO authenticator;
GRANT USAGE ON SCHEMA public TO web_user;
