import { test, expect } from '@playwright/test';
import { fetchDemoConfig, loginAs } from './helpers/login';

test('alice sees only Company-A products', async ({ page }) => {
  const demo = await fetchDemoConfig(page);
  await loginAs(page, 'alice@a.demo', demo.password);

  const table = page.locator('table').first();
  await expect(table).toBeVisible();
  // Wait for the products HTTP call to finish + table rows to render.
  await expect(table.locator('tbody tr').first()).toBeVisible({ timeout: 5_000 });
  const rows = await table.locator('tbody tr').allInnerTexts();
  expect(rows.length).toBeGreaterThan(0);
  // Bootstrap seeds A-Widget, A-Gadget, A-Doohickey for Company A.
  expect(rows.some(r => /A-/.test(r))).toBeTruthy();
  // No Company-B products should leak across the tenant boundary.
  expect(rows.every(r => !/B-/.test(r))).toBeTruthy();
});

test('carol sees only Company-B products', async ({ page }) => {
  const demo = await fetchDemoConfig(page);
  await loginAs(page, 'carol@b.demo', demo.password);

  const table = page.locator('table').first();
  await expect(table).toBeVisible();
  // Wait for the products HTTP call to finish + table rows to render.
  await expect(table.locator('tbody tr').first()).toBeVisible({ timeout: 5_000 });
  const rows = await table.locator('tbody tr').allInnerTexts();
  expect(rows.length).toBeGreaterThan(0);
  expect(rows.some(r => /B-/.test(r))).toBeTruthy();
  expect(rows.every(r => !/A-/.test(r))).toBeTruthy();
});
