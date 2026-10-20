import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright config for the base demo stack (examples/products/).
 *
 * Tests run against the live docker-compose stack — start it first:
 *
 *   docker compose up -d
 *   # wait until bootstrap finishes:
 *   docker compose logs -f bootstrap
 *
 * Then:
 *
 *   npm run test:e2e:install     # one-off: install Chromium
 *   npm run test:e2e             # headless
 *   npm run test:e2e:ui          # interactive UI mode
 *
 * No webServer block on purpose: a Compose-up takes 1-2 min on a cold start
 * and the bootstrap container is one-shot, so Playwright's auto-start would
 * just re-implement Compose.
 */
export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,                 // OIDC session reuse fights with parallelism
  workers: 1,
  retries: process.env['CI'] ? 1 : 0,
  reporter: process.env['CI'] ? [['github'], ['list']] : 'list',
  timeout: 20_000,
  expect: { timeout: 4_000 },
  use: {
    baseURL: process.env['E2E_BASE_URL'] || 'http://localhost:8089',
    ignoreHTTPSErrors: true,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure'
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } }
  ]
});
