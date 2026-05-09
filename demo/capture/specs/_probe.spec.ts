import { test } from '@playwright/test';
import { bakeAuth } from './_lib/auth';

test('probe drag attrs', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 1100 });
  await bakeAuth(page);
  await page.goto('/');
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(1_500);

  const card = page.locator('div.cursor-move').filter({ hasText: 'go-fileserver' }).first();
  const html = await card.evaluate((el) => el.outerHTML.slice(0, 500));
  const draggable = await card.getAttribute('draggable');
  console.log('DRAGGABLE_ATTR:', draggable);
  console.log('OUTER_HTML:', html);

  // Where on the page does intel-nuc machine card sit?
  const target = page.locator('div').filter({
    has: page.getByRole('heading', { name: 'intel-nuc' }),
  }).first();
  const tBox = await target.boundingBox();
  console.log('INTELNUC_BOX:', JSON.stringify(tBox));
});
