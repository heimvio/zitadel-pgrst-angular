-- ============================================================================
-- 02_provisioning.sql — Org-scoped user/role provisioning (core)
-- ----------------------------------------------------------------------------
-- Lets an ORG_OWNER (= the role returned by auth.org_admin_role(); default
-- 'org_owner') create users, assign/revoke roles, list and remove users
-- WITHIN THEIR OWN ORG.
--
-- Identity creation in Zitadel happens client-side (the SPA calls the Zitadel
-- management API with the caller's own OIDC token — see angular-provisioning).
-- This file only touches the DB mirror: auth.users + auth.user_roles, both
-- already created by 01_auth_schema.sql.
--
-- Conventions:
--   - auth.* RPCs are SECURITY DEFINER (may write auth.*), gating is explicit.
--   - public.* are thin wrappers exposed by PostgREST as /rpc/<name>.
--   - Idempotent on UNIQUE bridge columns (zitadel_sub, zitadel_org_id).
--
-- Override the admin role name per-app:
--   CREATE OR REPLACE FUNCTION auth.org_admin_role() RETURNS text
--   LANGUAGE sql IMMUTABLE AS $$ SELECT 'hausverwalter'::text $$;
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Configurable role names (override in your app's bootstrap if needed)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth.org_admin_role() RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT 'org_owner'::text
$$;

CREATE OR REPLACE FUNCTION auth.iam_admin_role() RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT 'iam_org_owner'::text
$$;

-- ----------------------------------------------------------------------------
-- Internal authz helpers
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth._require_org_admin() RETURNS void
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = auth, pg_temp AS $$
BEGIN
  IF NOT auth.has_role(auth.org_admin_role()) THEN
    RAISE EXCEPTION 'forbidden: % role required', auth.org_admin_role()
      USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION auth._require_iam_admin() RETURNS void
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = auth, pg_temp AS $$
BEGIN
  IF NOT auth.has_role(auth.iam_admin_role()) THEN
    RAISE EXCEPTION 'forbidden: % role required', auth.iam_admin_role()
      USING ERRCODE = '42501';
  END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- Org provisioning — IAM-level (creating new tenant orgs)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth.provision_org(p_zitadel_org_id text, p_name text)
  RETURNS uuid
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = auth, pg_temp AS $$
DECLARE
  v_id uuid;
BEGIN
  PERFORM auth._require_iam_admin();

  IF p_zitadel_org_id IS NULL OR p_zitadel_org_id = '' THEN
    RAISE EXCEPTION 'p_zitadel_org_id required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO auth.organizations (zitadel_org_id, name)
  VALUES (p_zitadel_org_id, NULLIF(p_name, ''))
  ON CONFLICT (zitadel_org_id) DO UPDATE
    SET name = COALESCE(EXCLUDED.name, auth.organizations.name)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- User provisioning — ORG-level (caller's own org only)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth.provision_user(
  p_zitadel_sub text,
  p_email       text,
  p_roles       text[] DEFAULT '{}'::text[]
) RETURNS uuid
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = auth, pg_temp AS $$
DECLARE
  v_org    uuid := auth.org_id();
  v_user   uuid;
  v_role   text;
BEGIN
  PERFORM auth._require_org_admin();

  IF v_org IS NULL THEN
    RAISE EXCEPTION 'caller has no org context' USING ERRCODE = '42501';
  END IF;
  IF p_zitadel_sub IS NULL OR p_zitadel_sub = '' THEN
    RAISE EXCEPTION 'p_zitadel_sub required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO auth.users (zitadel_sub, org_id, email)
  VALUES (p_zitadel_sub, v_org, NULLIF(p_email, ''))
  ON CONFLICT (zitadel_sub) DO UPDATE
    SET email = COALESCE(EXCLUDED.email, auth.users.email)
  RETURNING id INTO v_user;

  -- Org-scope guard: if the user already existed in a different org, refuse.
  IF (SELECT org_id FROM auth.users WHERE id = v_user) <> v_org THEN
    RAISE EXCEPTION 'user belongs to a different org' USING ERRCODE = '42501';
  END IF;

  IF p_roles IS NOT NULL THEN
    FOREACH v_role IN ARRAY p_roles LOOP
      IF v_role IS NOT NULL AND v_role <> '' THEN
        INSERT INTO auth.user_roles (user_id, role)
        VALUES (v_user, v_role)
        ON CONFLICT (user_id, role) DO NOTHING;
      END IF;
    END LOOP;
  END IF;

  RETURN v_user;
END;
$$;

-- ----------------------------------------------------------------------------
-- Role assignment — ORG-level
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth.assign_role(p_user_id uuid, p_role text)
  RETURNS void
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = auth, pg_temp AS $$
DECLARE
  v_target_org uuid;
BEGIN
  PERFORM auth._require_org_admin();

  IF p_role IS NULL OR p_role = '' THEN
    RAISE EXCEPTION 'p_role required' USING ERRCODE = '22023';
  END IF;

  SELECT org_id INTO v_target_org FROM auth.users WHERE id = p_user_id;
  IF v_target_org IS NULL THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_target_org <> auth.org_id() THEN
    RAISE EXCEPTION 'user belongs to a different org' USING ERRCODE = '42501';
  END IF;

  INSERT INTO auth.user_roles (user_id, role)
  VALUES (p_user_id, p_role)
  ON CONFLICT (user_id, role) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION auth.revoke_role(p_user_id uuid, p_role text)
  RETURNS void
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = auth, pg_temp AS $$
DECLARE
  v_target_org uuid;
BEGIN
  PERFORM auth._require_org_admin();

  SELECT org_id INTO v_target_org FROM auth.users WHERE id = p_user_id;
  IF v_target_org IS NULL THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_target_org <> auth.org_id() THEN
    RAISE EXCEPTION 'user belongs to a different org' USING ERRCODE = '42501';
  END IF;

  DELETE FROM auth.user_roles
   WHERE user_id = p_user_id AND role = p_role;
END;
$$;

-- ----------------------------------------------------------------------------
-- List users in caller's org
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth.list_org_users()
  RETURNS TABLE (
    id          uuid,
    email       text,
    roles       text[],
    zitadel_sub text,
    created_at  timestamptz
  )
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = auth, pg_temp AS $$
BEGIN
  PERFORM auth._require_org_admin();
  RETURN QUERY
    SELECT u.id,
           u.email,
           COALESCE((SELECT array_agg(r.role) FROM auth.user_roles r WHERE r.user_id = u.id), '{}'::text[]) AS roles,
           u.zitadel_sub,
           u.created_at
      FROM auth.users u
     WHERE u.org_id = auth.org_id()
     ORDER BY u.created_at;
END;
$$;

-- ----------------------------------------------------------------------------
-- Remove user (DB-side only; Zitadel identity is the app's concern)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth.remove_user(p_user_id uuid)
  RETURNS void
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = auth, pg_temp AS $$
DECLARE
  v_target_org uuid;
BEGIN
  PERFORM auth._require_org_admin();

  SELECT org_id INTO v_target_org FROM auth.users WHERE id = p_user_id;
  IF v_target_org IS NULL THEN
    RETURN;  -- already gone, idempotent
  END IF;
  IF v_target_org <> auth.org_id() THEN
    RAISE EXCEPTION 'user belongs to a different org' USING ERRCODE = '42501';
  END IF;

  DELETE FROM auth.users WHERE id = p_user_id;
  -- auth.user_roles cascades via FK
END;
$$;

-- ----------------------------------------------------------------------------
-- PostgREST exposure: public.* wrappers
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.provision_org(p_zitadel_org_id text, p_name text)
  RETURNS uuid LANGUAGE sql VOLATILE AS $$
  SELECT auth.provision_org(p_zitadel_org_id, p_name)
$$;

CREATE OR REPLACE FUNCTION public.provision_user(p_zitadel_sub text, p_email text, p_roles text[])
  RETURNS uuid LANGUAGE sql VOLATILE AS $$
  SELECT auth.provision_user(p_zitadel_sub, p_email, p_roles)
$$;

CREATE OR REPLACE FUNCTION public.assign_role(p_user_id uuid, p_role text)
  RETURNS void LANGUAGE sql VOLATILE AS $$
  SELECT auth.assign_role(p_user_id, p_role)
$$;

CREATE OR REPLACE FUNCTION public.revoke_role(p_user_id uuid, p_role text)
  RETURNS void LANGUAGE sql VOLATILE AS $$
  SELECT auth.revoke_role(p_user_id, p_role)
$$;

CREATE OR REPLACE FUNCTION public.list_org_users()
  RETURNS TABLE (id uuid, email text, roles text[], zitadel_sub text, created_at timestamptz)
  LANGUAGE sql STABLE AS $$
  SELECT * FROM auth.list_org_users()
$$;

CREATE OR REPLACE FUNCTION public.remove_user(p_user_id uuid)
  RETURNS void LANGUAGE sql VOLATILE AS $$
  SELECT auth.remove_user(p_user_id)
$$;

-- ----------------------------------------------------------------------------
-- Grants
-- ----------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION
  auth.org_admin_role(),
  auth.iam_admin_role(),
  auth._require_org_admin(),
  auth._require_iam_admin(),
  auth.provision_org(text, text),
  auth.provision_user(text, text, text[]),
  auth.assign_role(uuid, text),
  auth.revoke_role(uuid, text),
  auth.list_org_users(),
  auth.remove_user(uuid),
  public.provision_org(text, text),
  public.provision_user(text, text, text[]),
  public.assign_role(uuid, text),
  public.revoke_role(uuid, text),
  public.list_org_users(),
  public.remove_user(uuid)
TO web_user;
