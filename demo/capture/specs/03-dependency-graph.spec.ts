import { test } from '@playwright/test';
import { bakeAuth } from './_lib/auth';

/**
 * Capture the dependency graph page: ReactFlow renders the service graph,
 * we pan a touch, zoom, and click a node so the impact panel populates.
 */
test('dependency graph', async ({ page }) => {
  await bakeAuth(page);
  await page.goto('/');
  // The shell opens a WebSocket immediately and never goes idle, so wait
  // on the Cluster heading instead of networkidle.
  await page.getByRole('heading', { name: 'Cluster Overview' }).waitFor({ timeout: 15_000 });

  // The shell uses a button-driven nav, not URL routes — the / route
  // always paints the cluster overview, so click into Dependencies.
  await page.getByRole('button', { name: 'Dependencies' }).click();

  // ReactFlow paints inside a container with class "react-flow"; wait for
  // at least a few nodes to appear before we start animating.
  const flow = page.locator('.react-flow');
  await flow.waitFor({ state: 'visible', timeout: 15_000 });
  await page.locator('.react-flow__node').first().waitFor({ state: 'visible', timeout: 15_000 });
  // Give the auto-layout a beat to settle so the first frame isn't messy.
  await page.waitForTimeout(1_500);

  // Grab the viewport handle so we can dispatch wheel/drag events to it.
  const viewport = page.locator('.react-flow__viewport');
  const box = await flow.boundingBox();
  if (!box) throw new Error('react-flow has no bounding box');

  const cx = box.x + box.width / 2;
  const cy = box.y + box.height / 2;

  // Slow zoom-in: a few wheel ticks so the camera drifts in instead of
  // teleporting. ReactFlow listens for wheel on the pane. Lighter than
  // before — too many ticks pushes nodes off-screen.
  for (let i = 0; i < 3; i++) {
    await page.mouse.move(cx, cy);
    await page.mouse.wheel(0, -120);
    await page.waitForTimeout(220);
  }

  // Hold the graph view. Earlier versions of this spec clicked a node to
  // populate the side panel, but that side panel offers a "Run
  // Diagnostics" action that navigates to the Health Dashboard, so the
  // recording ended on the wrong page. Showing the graph is enough.
  await page.waitForTimeout(4_500);
});
