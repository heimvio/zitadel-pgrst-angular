-- ============================================================================
-- auth_schema.sql — Generischer Zitadel↔Postgres Identitäts-/RLS-Vertrag
-- ----------------------------------------------------------------------------
-- Single Source of Truth. Kennt NUR Zitadel-Org + -User. Rollen werden
-- DB-seitig in auth.user_roles vergeben (rollennamen-agnostisch).
-- Idempotent, ON_ERROR_STOP-fest (frisch UND wiederholt fehlerfrei).
--
-- PostgREST setzt aus dem (per JWKS/RS256 verifizierten) Zitadel-JWT die GUC
-- `request.jwt.claims`. Es gibt KEINE Zitadel-Action, KEIN nginx-Lua,
-- KEIN HMAC, KEIN Mint-Zeit-Resolver. Org/User entstehen Just-in-Time
-- (auth.ensure_principal, via PGRST_DB_PRE_REQUEST).
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS auth;
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()

-- ----------------------------------------------------------------------------
-- Anker-Tabellen (die einzigen DB-Brücken zu Zitadel)
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

-- Reiner Speicher. KEINE vordefinierten Rollennamen — die App definiert sie.
CREATE TABLE IF NOT EXISTS auth.user_roles (
  user_id  uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role     text NOT NULL,
  PRIMARY KEY (user_id, role)
);

-- ----------------------------------------------------------------------------
-- Claim-Zugriff
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

-- Org-ID-Claim-Key ist konfigurierbar (Schritt-0-Ergebnis wird hier fixiert).
-- Standard: Zitadel-Reserved-Claims; mehrere Kandidaten werden gecoalesced,
-- damit das Beispiel ohne Vorab-Empirie läuft und in Phase B verschlankt wird.
CREATE OR REPLACE FUNCTION auth._zitadel_org_id() RETURNS text
  LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT COALESCE(
    auth._claims() ->> 'urn:zitadel:iam:user:resourceowner:id',
    auth._claims() ->> 'urn:zitadel:iam:org:id',
    auth._claims() ->> 'org_id'
  )
$$;

-- ----------------------------------------------------------------------------
-- Just-in-Time-Spiegel — via PGRST_DB_PRE_REQUEST=auth.ensure_principal
-- SECURITY DEFINER: darf auth.* schreiben, obwohl Caller das nicht darf.
-- Vergibt KEINE Rollen (sicherer Default-Deny bis ein App-Admin zuweist).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth.ensure_principal() RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = auth, pg_temp AS $$
DECLARE
  v_sub  text := auth.sub();
  v_oid  text := auth._zitadel_org_id();
  v_org  uuid;
BEGIN
  IF v_sub IS NULL OR v_oid IS NULL THEN
    RETURN;  -- kein verifizierter Principal -> no-op
  END IF;

  -- PostgREST fährt GET in einer READ-ONLY-Transaktion (PGRST_DB_PRE_REQUEST
  -- läuft trotzdem mit). Schreiben ist dort unmöglich -> still no-op. Der
  -- Login-Client ruft public.ensure_principal() einmalig per POST (schreibbar)
  -- auf; spätestens der erste Schreib-Request legt den Principal sonst an.
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
  -- id bleibt stabil; org_id wird bewusst NICHT umgeschrieben.
END;
$$;

-- ----------------------------------------------------------------------------
-- STABLE-Accessoren (1 indizierter Lookup; SECURITY DEFINER liest auth.*)
-- Vertrag wird AUSSCHLIESSLICH hier geändert.
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

-- Frontend-Profil-Quelle (statt Custom-Claims).
CREATE OR REPLACE FUNCTION public.whoami() RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'user_id', auth.user_id(),
    'org_id',  auth.org_id(),
    'roles',   to_jsonb(auth.roles())
  )
$$;

-- VOLATILE-Wrapper, von PostgREST als POST /rpc/ensure_principal exponiert.
-- Der Login-Client ruft dies einmal direkt nach dem Login auf (schreibbare
-- Transaktion) -> JIT-Spiegel sicher angelegt, auch wenn nur GETs folgen.
CREATE OR REPLACE FUNCTION public.ensure_principal() RETURNS jsonb
  LANGUAGE sql VOLATILE AS $$
  SELECT auth.ensure_principal();
  SELECT public.whoami();
$$;

-- ----------------------------------------------------------------------------
-- Grants: die PostgREST-DB-Rolle (web_user, siehe 00_roles.sql) darf NUR via
-- Funktionen an auth.* heran. Tabellen ohne direkten Zugriff; SECURITY DEFINER
-- kapselt sie. Autorisierung passiert 100% in RLS via auth.*.
-- ----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA auth TO web_user;
GRANT EXECUTE ON FUNCTION
  auth._claims(), auth.sub(), auth._zitadel_org_id(),
  auth.ensure_principal(), auth.user_id(), auth.org_id(),
  auth.roles(), auth.has_role(text),
  public.whoami(), public.ensure_principal()
TO web_user;
