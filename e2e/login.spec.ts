import { test, expect } from '@playwright/test';
import { fetchDemoConfig, loginAs } from './helpers/login';

test('alice can log in; whoami profile shows org + roles', async ({ page }) => {
  const demo = await fetchDemoConfig(page);
  await loginAs(page, 'alice@a.demo', demo.password);

  // The products view renders a JSON preview of the whoami signal.
  const pre = page.locator('pre');
  await expect(pre).toBeVisible();
  const profile = await pre.first().textContent();
  expect(profile).toMatch(/"org_id":\s*"[0-9a-f-]+"/i);
  // Roles must include at least one of the bootstrap-assigned ones.
  expect(profile).toMatch(/"roles":\s*\[[^\]]*"(staff|org_owner)"/);

  // Logout button is present (full OIDC end_session round-trip depends on
  // Zitadel's post_logout_redirect_uri being whitelisted; that's a deploy
  // concern, not a base-library smoke).
  await expect(page.getByRole('button', { name: /logout/i })).toBeVisible();
});
