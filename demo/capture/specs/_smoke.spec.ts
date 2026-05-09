import { test, expect } from '@playwright/test';
import { bakeAuth } from './_lib/auth';

test('auth bakes and the SPA loads past the login wall', async ({ page }) => {
  await bakeAuth(page);
  await page.goto('/');
  await page.waitForLoadState('networkidle');

  // We want to see something that only appears once authenticated. The
  // login form has the word "Sign in" or similar. Authed shells render a
  // navigation link to the cluster overview.
  await expect(page).not.toHaveURL(/\/login/i);
});
