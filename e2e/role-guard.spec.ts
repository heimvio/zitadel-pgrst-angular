import { test, expect } from '@playwright/test';
import { fetchDemoConfig, loginAs } from './helpers/login';

test('bob (customer, no org_owner) is bounced from /admin/users', async ({ page }) => {
  const demo = await fetchDemoConfig(page);
  await loginAs(page, 'bob@a.demo', demo.password);

  await page.goto('/admin/users');
  // roleGuard fallback redirects to '/'. We must NOT see the users-list heading.
  await expect(page).toHaveURL(/\/(?:$|\?)/, { timeout: 4_000 });
  await expect(page.getByRole('heading', { name: /users/i })).toHaveCount(0);
});
