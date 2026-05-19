-- ============================================================================
-- 02_products.sql — EXAMPLE APP (not part of the generic core!)
-- ----------------------------------------------------------------------------
-- Per-organization product list. Shows org isolation AND role gating with the
-- app-owned roles `customer` (read only) and `staff` (read+write).
-- The core does NOT know these names — they come from auth.user_roles.
-- ============================================================================

-- org_id DEFAULT auth.org_id(): org-scoped tables fill in the caller's org
-- automatically -> clients never send org_id, RLS WITH CHECK still enforces it.
-- (Core pattern for the EXTENDING contract.)
CREATE TABLE IF NOT EXISTS public.products (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL DEFAULT auth.org_id() REFERENCES auth.organizations(id) ON DELETE CASCADE,
  name       text NOT NULL,
  price      numeric(10,2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_products_org ON public.products(org_id);

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

-- Read: own org's catalog, visible to customer OR staff.
DROP POLICY IF EXISTS products_read ON public.products;
CREATE POLICY products_read ON public.products
  FOR SELECT
  USING (
    org_id = auth.org_id()
    AND (auth.has_role('customer') OR auth.has_role('staff'))
  );

-- Write (insert/update/delete): staff only, own org's catalog only.
DROP POLICY IF EXISTS products_write ON public.products;
CREATE POLICY products_write ON public.products
  FOR ALL
  USING      (org_id = auth.org_id() AND auth.has_role('staff'))
  WITH CHECK (org_id = auth.org_id() AND auth.has_role('staff'));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.products TO web_user;
