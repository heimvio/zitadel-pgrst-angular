import { test, expect } from '@playwright/test';
import { fetchDemoConfig, loginAs } from './helpers/login';

test('alice (org_owner) opens /admin/users and the list loads', async ({ page }) => {
  const demo = await fetchDemoConfig(page);
  await loginAs(page, 'alice@a.demo', demo.password);

  await page.goto('/admin/users');
  // <base-org-users-list> renders a heading + the Add-user button.
  await expect(page.getByRole('heading', { name: /users/i })).toBeVisible({ timeout: 4_000 });
  await expect(page.getByRole('button', { name: /add user/i })).toBeVisible();

  // The list should at least contain alice herself (and her colleague bob).
  await expect(page.getByText('alice@a.demo')).toBeVisible();
  await expect(page.getByText('bob@a.demo')).toBeVisible();
  // Carol is in a different org — must NOT appear (server-side RLS).
  await expect(page.getByText('carol@b.demo')).toHaveCount(0);
});

test('alice can open the add-user form and submit (provision_user round-trip)', async ({ page }) => {
  const demo = await fetchDemoConfig(page);
  await loginAs(page, 'alice@a.demo', demo.password);

  await page.goto('/admin/users');
  await page.getByRole('button', { name: /add user/i }).click();

  const stamp = Date.now();
  const email = `e2e-${stamp}@a.demo`;
  await page.locator('input[name="email"]').fill(email);
  await page.locator('input[name="givenName"]').fill('E2E');
  await page.locator('input[name="familyName"]').fill('Test');
  // Pick the 'customer' role inside the add-user form (avoid matching the
  // checkboxes inside existing user rows in the table).
  await page.locator('form').getByRole('checkbox', { name: 'customer' }).check();

  await page.getByRole('button', { name: /create user/i }).click();

  // After saving, the dialog auto-closes (onSaved -> showAdd=false + reload).
  // The new email should appear in the list.
  await expect(page.getByText(email)).toBeVisible({ timeout: 8_000 });
});
