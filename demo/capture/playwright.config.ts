import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.PORTOSER_UI_URL ?? 'http://localhost:8989';

export default defineConfig({
  testDir: './specs',
  outputDir: './test-results',
  timeout: 60_000,
  fullyParallel: false,
  forbidOnly: false,
  retries: 0,
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL,
    headless: true,
    viewport: { width: 1280, height: 800 },
    deviceScaleFactor: 2,
    video: {
      mode: 'on',
      size: { width: 1280, height: 800 },
    },
    screenshot: 'only-on-failure',
    trace: 'off',
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
