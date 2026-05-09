import { test } from '@playwright/test';
import { bakeAuth } from './_lib/auth';

/**
 * Capture the Knowledge Base page: navigate, browse playbooks list,
 * expand one to show its content + occurrence count.
 */
test('knowledge base', async ({ page }) => {
  await bakeAuth(page);
  await page.goto('/');
  await page.waitForLoadState('networkidle');

  await page.getByRole('button', { name: /Knowledge Base/i }).click();
  // KB page mounts asynchronously; wait for its hero heading or first card.
  await page.waitForTimeout(2_000);

  // Try to find a category filter or playbook card. We don't know the exact
  // markup so we use a generous regex and fall back gracefully.
  const filterButton = page
    .getByRole('button', { name: /troubleshoot|category|filter/i })
    .first();
  if (await filterButton.count()) {
    await filterButton.click().catch(() => {});
    await page.waitForTimeout(800);
  }

  // Expand the first playbook entry by clicking its title or chevron.
  const playbook = page
    .locator('[data-testid="playbook-card"], article, li')
    .filter({ hasText: /image[- ]?pull|port[- ]?conflict|disk[- ]?full|dns/i })
    .first();
  if (await playbook.count()) {
    await playbook.click().catch(() => {});
    await page.waitForTimeout(2_500);
  }

  // Hold the final composed frame.
  await page.waitForTimeout(2_000);
});
