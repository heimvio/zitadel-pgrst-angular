-- ============================================================================
-- auth_schema.sql — Generic Zitadel<->Postgres identity / RLS contract
-- ----------------------------------------------------------------------------
-- Single source of truth. Knows ONLY Zitadel org + user. Roles are assigned
-- in the DB in auth.user_roles (role-name-agnostic).
-- Idempotent, ON_ERROR_STOP-safe (clean AND repeated, error-free).
--
-- PostgREST sets the GUC `request.jwt.claims` from the (JWKS/RS256-verified)
-- Zitadel JWT. There is NO Zitadel action, NO nginx-Lua, NO HMAC, NO
-- mint-time resolver. Org/user are created just-in-time
-- (auth.ensure_principal, via PGRST_DB_PRE_REQUEST).
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS auth;
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()

-- ----------------------------------------------------------------------------
-- Migration tracking (used by base.sh's migrations runner). Shared by lib AND
-- app migrations — one source of truth per database.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auth.schema_migrations (
  version    text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- Anchor tables (the only DB bridges to Zitadel)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auth.organizations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  zitadel_org_id  text UNIQUE NOT NULL,
  name            text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS auth.users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  zitadel_sub   text UNIQUE NOT NULL,
  org_id        uuid NOT NULL REFERENCES auth.organizations(id) ON DELETE RESTRICT,
  email         text,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_auth_users_org ON auth.users(org_id);

-- Pure storage. NO predefined role names — the app defines them.
CREATE TABLE IF NOT EXISTS auth.user_roles (
  user_id  uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role     text NOT NULL,
  PRIMARY KEY (user_id, role)
);

-- ----------------------------------------------------------------------------
-- Claim access
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth._claims() RETURNS jsonb
  LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT COALESCE(
           NULLIF(current_setting('request.jwt.claims', true), ''),
           '{}'
         )::jsonb
$$;

CREATE OR REPLACE FUNCTION auth.sub() RETURNS text
  LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT auth._claims() ->> 'sub'
$$;

-- The org-id claim key is configurable (the step-0 result is fixed here).
-- Default: Zitadel reserved claims; several candidates are coalesced so the
-- example runs without prior empirical checks and can be trimmed in phase B.
CREATE OR REPLACE FUNCTION auth._zitadel_org_id() RETURNS text
  LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT COALESCE(
    auth._claims() ->> 'urn:zitadel:iam:user:resourceowner:id',
    auth._claims() ->> 'urn:zitadel:iam:org:id',
    auth._claims() ->> 'org_id'
  )
$$;

-- ----------------------------------------------------------------------------
-- Just-in-time mirror — via PGRST_DB_PRE_REQUEST=auth.ensure_principal
-- SECURITY DEFINER: may write auth.* even though the caller may not.
-- Assigns NO roles (safe default-deny until an app admin assigns them).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth.ensure_principal() RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = auth, pg_temp AS $$
DECLARE
  v_sub  text := auth.sub();
  v_oid  text := auth._zitadel_org_id();
  v_org  uuid;
BEGIN
  IF v_sub IS NULL OR v_oid IS NULL THEN
    RETURN;  -- no verified principal -> no-op
  END IF;

  -- PostgREST runs GET in a READ-ONLY transaction (PGRST_DB_PRE_REQUEST still
  -- runs). Writing is impossible there -> stay a no-op. The login client calls
  -- public.ensure_principal() once via POST (writable); otherwise the first
  -- write request creates the principal.
  IF current_setting('transaction_read_only') = 'on' THEN
    RETURN;
  END IF;

  INSERT INTO auth.organizations (zitadel_org_id)
  VALUES (v_oid)
  ON CONFLICT (zitadel_org_id) DO NOTHING;

  SELECT id INTO v_org FROM auth.organizations WHERE zitadel_org_id = v_oid;

  INSERT INTO auth.users (zitadel_sub, org_id, email)
  VALUES (v_sub, v_org, auth._claims() ->> 'email')
  ON CONFLICT (zitadel_sub) DO UPDATE
    SET email = COALESCE(EXCLUDED.email, auth.users.email);
  -- id stays stable; org_id is deliberately NOT rewritten.
END;
$$;

-- ----------------------------------------------------------------------------
-- STABLE accessors (1 indexed lookup; SECURITY DEFINER reads auth.*)
-- The contract is changed EXCLUSIVELY here.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth.user_id() RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = auth, pg_temp AS $$
  SELECT id FROM auth.users WHERE zitadel_sub = auth.sub()
$$;

CREATE OR REPLACE FUNCTION auth.org_id() RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = auth, pg_temp AS $$
  SELECT org_id FROM auth.users WHERE zitadel_sub = auth.sub()
$$;

CREATE OR REPLACE FUNCTION auth.roles() RETURNS text[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = auth, pg_temp AS $$
  SELECT COALESCE(array_agg(r.role), '{}')
  FROM auth.user_roles r
  WHERE r.user_id = (SELECT id FROM auth.users WHERE zitadel_sub = auth.sub())
$$;

CREATE OR REPLACE FUNCTION auth.has_role(p_role text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = auth, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM auth.user_roles r
    WHERE r.user_id = (SELECT id FROM auth.users WHERE zitadel_sub = auth.sub())
      AND r.role = p_role
  )
$$;

-- Frontend profile source (instead of custom claims).
CREATE OR REPLACE FUNCTION public.whoami() RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'user_id', auth.user_id(),
    'org_id',  auth.org_id(),
    'roles',   to_jsonb(auth.roles())
  )
$$;

-- VOLATILE wrapper, exposed by PostgREST as POST /rpc/ensure_principal.
-- The login client calls this once right after login (writable
-- transaction) -> JIT mirror reliably created, even if only GETs follow.
CREATE OR REPLACE FUNCTION public.ensure_principal() RETURNS jsonb
  LANGUAGE sql VOLATILE AS $$
  SELECT auth.ensure_principal();
  SELECT public.whoami();
$$;

-- ----------------------------------------------------------------------------
-- Grants: the PostgREST DB role (web_user, see 00_roles.sql) may reach auth.*
-- ONLY via functions. Tables have no direct access; SECURITY DEFINER
-- encapsulates them. Authorization happens 100% in RLS via auth.*.
-- ----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA auth TO web_user;
GRANT EXECUTE ON FUNCTION
  auth._claims(), auth.sub(), auth._zitadel_org_id(),
  auth.ensure_principal(), auth.user_id(), auth.org_id(),
  auth.roles(), auth.has_role(text),
  public.whoami(), public.ensure_principal()
TO web_user;
