-- ============================================================================
-- 02_app_products.sql — BEISPIEL-APP (nicht Teil des generischen Kerns!)
-- ----------------------------------------------------------------------------
-- Produktliste pro Organisation. Zeigt Org-Isolation UND Rollen-Gating mit
-- den App-eigenen Rollen `customer` (nur lesen) und `staff` (lesen+schreiben).
-- Die Basis kennt diese Namen NICHT — sie kommen aus auth.user_roles.
-- In Phase B wird die Grenze auth_schema.sql <-> App final gezogen.
-- ============================================================================

-- org_id DEFAULT auth.org_id(): org-scoped Tabellen tragen die Org des
-- Aufrufers automatisch ein -> Clients senden kein org_id, RLS WITH CHECK
-- bleibt trotzdem zwingend. (Kernmuster für den EXTENDING-Vertrag.)
CREATE TABLE IF NOT EXISTS public.products (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL DEFAULT auth.org_id() REFERENCES auth.organizations(id) ON DELETE CASCADE,
  name       text NOT NULL,
  price      numeric(10,2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_products_org ON public.products(org_id);

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

-- Lesen: eigener Org-Katalog, sichtbar für customer ODER staff.
DROP POLICY IF EXISTS products_read ON public.products;
CREATE POLICY products_read ON public.products
  FOR SELECT
  USING (
    org_id = auth.org_id()
    AND (auth.has_role('customer') OR auth.has_role('staff'))
  );

-- Schreiben (insert/update/delete): nur staff, nur eigener Org-Katalog.
DROP POLICY IF EXISTS products_write ON public.products;
CREATE POLICY products_write ON public.products
  FOR ALL
  USING      (org_id = auth.org_id() AND auth.has_role('staff'))
  WITH CHECK (org_id = auth.org_id() AND auth.has_role('staff'));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.products TO web_user;
