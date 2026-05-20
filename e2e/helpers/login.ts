import { expect, Page } from '@playwright/test';

export interface DemoConfig {
  password: string;
  users: string[];
}

/**
 * Fetch the live runtime config served by the example app's nginx. This is the
 * same `config.json` the SPA loads on startup, so the tests don't hardcode
 * credentials and stay in sync with whatever bootstrap.sh produced.
 *
 * Resolves against `use.baseURL` from playwright.config.ts.
 */
export async function fetchDemoConfig(page: Page): Promise<DemoConfig> {
  const res = await page.request.get('/config.json');
  expect(res.ok(), 'config.json must be reachable on the example app').toBeTruthy();
  const cfg = await res.json();
  if (!cfg.demo?.password) throw new Error('config.json has no demo.password — bootstrap not finished?');
  return cfg.demo as DemoConfig;
}

/**
 * Drive the Zitadel hosted login UI for a demo user. Zitadel's classic login
 * is a two-step form (loginName → password). We try the common selectors in
 * order and accept either step layout.
 */
export async function loginAs(page: Page, login: string, password: string): Promise<void> {
  // 1. Go to landing and click "Login" — triggers OIDC redirect to Zitadel.
  await page.goto('/');
  await page.getByRole('button', { name: /login/i }).click();

  // 2. Username step.
  await page.waitForURL(/\/ui\/login/, { timeout: 5_000 });
  const loginInput = page.locator(
    '#loginName, input[name="loginName"], input[name="username"], input[type="email"], input[type="text"]'
  ).first();
  await expect(loginInput).toBeVisible({ timeout: 4_000 });
  await loginInput.fill(login);
  await page.locator('button[type="submit"], #submit-button, button:has-text("next")').first().click();

  // 3. Password step.
  const pwInput = page.locator(
    '#password, input[name="password"], input[type="password"]'
  ).first();
  await expect(pwInput).toBeVisible({ timeout: 4_000 });
  await pwInput.fill(password);
  await page.locator('button[type="submit"], #submit-button, button:has-text("sign in"), button:has-text("submit")').first().click();

  // 4. Land back on the SPA. APP_INITIALIZER finishes the code flow and loads whoami.
  await page.waitForURL((u) => !u.toString().includes('/ui/login'), { timeout: 5_000 });
  await page.waitForURL((u) => !u.toString().includes('/callback'), { timeout: 5_000 });

  // 5. Wait until the products view actually rendered — the Logout button is
  //    the most reliable marker (only present when auth.profile() is non-null).
  await expect(page.getByRole('button', { name: /logout/i })).toBeVisible({ timeout: 5_000 });
}

/** Quick logout via the in-app button. */
export async function logout(page: Page): Promise<void> {
  await page.goto('/');
  await page.getByRole('button', { name: /logout/i }).click();
  await page.waitForURL(/.+/);
}
