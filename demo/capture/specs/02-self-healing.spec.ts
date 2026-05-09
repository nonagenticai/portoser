import { test } from '@playwright/test';
import { bakeAuth } from './_lib/auth';

/**
 * Self-healing scene: open the Health Dashboard. The page lists per-service
 * health, scores, and any in-flight remediation activity. Hover one row to
 * surface its detail tooltip, then sit on it long enough for live WS
 * updates to land.
 */
test('self-healing dashboard', async ({ page }) => {
  await bakeAuth(page);
  await page.goto('/');
  await page.waitForLoadState('networkidle');

  await page.getByRole('button', { name: /Health Dashboard/i }).click();
  await page.waitForTimeout(2_500);

  // Hover the first service row to reveal more detail. We don't know the
  // exact selector so we use a permissive one — `tr` first, fall back to
  // any row-shaped element.
  const firstRow = page
    .locator('tr, [role="row"], [data-testid="service-row"]')
    .filter({ hasText: /docker|gitea|postgres|redis/i })
    .first();
  if (await firstRow.count()) {
    await firstRow.hover().catch(() => {});
    await page.waitForTimeout(1_500);
  }

  // Hold long enough that WS updates visibly arrive a few times.
  await page.waitForTimeout(8_000);
});
