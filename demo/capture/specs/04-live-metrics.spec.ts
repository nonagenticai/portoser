import { test } from '@playwright/test';
import { bakeAuth } from './_lib/auth';

/**
 * Capture the Monitoring page: live CPU/memory chart updating from the
 * websocket. Hold for ~12s so several update ticks visibly land.
 */
test('live metrics', async ({ page }) => {
  await bakeAuth(page);
  await page.goto('/');
  await page.waitForLoadState('networkidle');

  await page.getByRole('button', { name: /Monitoring/i }).click();

  // Wait for the dashboard heading to actually paint — the page has a
  // network round-trip before the per-machine cards land, and the chart
  // selectors below may resolve to nothing until then.
  await page
    .getByRole('heading', { name: /Monitoring Dashboard/i })
    .waitFor({ state: 'visible', timeout: 15_000 });
  await page.waitForTimeout(1_500);

  // Hover over a chart so the tooltip surfaces if any. Best-effort — we
  // don't bail if the markup doesn't have a chart yet.
  const firstChart = page.locator('canvas, svg.recharts-surface, [class*=chart]').first();
  if (await firstChart.count()) {
    const box = await firstChart.boundingBox();
    if (box) {
      await page.mouse.move(box.x + box.width * 0.6, box.y + box.height * 0.5);
    }
  }

  // Hold long enough that a couple of WS update ticks visibly land.
  await page.waitForTimeout(14_000);
});
