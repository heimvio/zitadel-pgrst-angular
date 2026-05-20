import { test, expect } from '@playwright/test';
import { fetchDemoConfig } from './helpers/login';

test('landing page renders for anonymous users', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('button', { name: /login/i })).toBeVisible();
  // Demo user list seeded by bootstrap — read from the live config.
  const demo = await fetchDemoConfig(page);
  expect(demo.users.length).toBeGreaterThan(0);
  for (const u of demo.users) {
    await expect(page.getByText(u, { exact: false })).toBeVisible();
  }
});

test('config.json is served and shape matches the contract', async ({ page }) => {
  const res = await page.request.get('/config.json');
  expect(res.ok()).toBeTruthy();
  const cfg = await res.json();
  expect(cfg.postgrest.url).toMatch(/^https?:\/\//);
  expect(cfg.oidc.issuer).toMatch(/^https?:\/\//);
  expect(cfg.oidc.clientId).toBeTruthy();
  expect(cfg.oidc.scope).toContain('urn:zitadel:iam:user:resourceowner');
  // Audience scope is required for the provisioning building block to work.
  expect(cfg.oidc.scope).toContain('urn:zitadel:iam:org:project:id:zitadel:aud');
});
