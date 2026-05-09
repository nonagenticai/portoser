import { test } from '@playwright/test';
import { bakeAuth } from './_lib/auth';

/**
 * Hero scene: cluster overview → drag a service card from its current
 * machine onto another machine → DeploymentPanel shows the pending move →
 * click Deploy → success.
 *
 * react-dnd uses the HTML5 drag backend, so plain `dragTo` should work.
 * If it ever stops working, the fallback is dispatching dragstart /
 * dragover / drop events on the DOM nodes manually.
 */
test('hero drag-deploy', async ({ page }) => {
  // The cluster overview lays out all six machines in two rows of three;
  // a 800px viewport hides the bottom row. Bump the viewport for this
  // scene so intel-nuc stays in frame.
  await page.setViewportSize({ width: 1280, height: 1100 });

  await bakeAuth(page);
  await page.goto('/');
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(1_500);

  // The service card we want to move. Filter on text so we don't need to
  // know the precise data-testid the SPA uses.
  const sourceCard = page
    .locator('div.cursor-move')
    .filter({ hasText: 'go-fileserver' })
    .first();
  await sourceCard.waitFor({ state: 'visible', timeout: 10_000 });

  // The machine card we want to drop onto. The drop target in
  // MachineCard.jsx is the outer `bg-white rounded-lg border-2` div —
  // narrow on that so we don't catch a generic ancestor.
  const targetCard = page
    .locator('div.bg-white.rounded-lg.border-2')
    .filter({ has: page.getByRole('heading', { name: 'intel-nuc' }) })
    .first();
  await targetCard.waitFor({ state: 'visible', timeout: 10_000 });

  // react-dnd's HTML5 backend listens for native dragstart/dragover/drop
  // events with a real DataTransfer object. Playwright's locator.dragTo
  // and mouse.down/move/up don't fabricate those, so we dispatch them
  // ourselves. This is the documented Playwright/react-dnd workaround.
  await sourceCard.hover();
  await page.waitForTimeout(700);

  const dataTransfer = await page.evaluateHandle(() => new DataTransfer());
  await sourceCard.dispatchEvent('dragstart', { dataTransfer });
  await page.waitForTimeout(500);
  await targetCard.dispatchEvent('dragenter', { dataTransfer });
  await targetCard.dispatchEvent('dragover', { dataTransfer });
  await page.waitForTimeout(500);
  await targetCard.dispatchEvent('drop', { dataTransfer });
  await sourceCard.dispatchEvent('dragend', { dataTransfer });
  await page.waitForTimeout(2_500);

  // After the drop, the SPA should populate a DeploymentPanel with a
  // pending move and a Deploy button. Click it if we can find it.
  const deployButton = page
    .getByRole('button', { name: /^Deploy( Changes)?$/i })
    .first();
  if (await deployButton.count()) {
    await deployButton.click().catch(() => {});
  }
  // Hold the final composed frame.
  await page.waitForTimeout(4_500);
});
