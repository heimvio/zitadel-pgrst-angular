-- ============================================================================
-- V001__products_add_category.sql — DEMO MIGRATION
-- ----------------------------------------------------------------------------
-- Adds a 'category' column to public.products. Demonstrates the three-step
-- ADD-NOT-NULL pattern that survives concurrent writes:
--   1. ADD COLUMN nullable (no rewrite, instant on any size)
--   2. BACKFILL existing rows
--   3. SET NOT NULL (+ DEFAULT for future inserts)
--
-- Tracked in auth.schema_migrations by the base bootstrap. Runs once per DB,
-- inside a single transaction (so a failure aborts everything and re-tries
-- on the next bootstrap run).
-- ============================================================================

ALTER TABLE public.products ADD COLUMN IF NOT EXISTS category text;
CREATE INDEX IF NOT EXISTS idx_products_category ON public.products(category);

-- Backfill: NULL → 'general'. Idempotent: only touches rows that need it.
UPDATE public.products SET category = 'general' WHERE category IS NULL;

-- Tighten the column AFTER the backfill — otherwise concurrent inserts
-- between step 1 and step 3 would race with the constraint.
ALTER TABLE public.products
  ALTER COLUMN category SET DEFAULT 'general',
  ALTER COLUMN category SET NOT NULL;
