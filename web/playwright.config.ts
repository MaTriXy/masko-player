import { defineConfig, devices } from '@playwright/test';

const port = Number(process.env.PORT ?? 4174);

export default defineConfig({
  testDir: 'test/browser',
  testMatch: '*.spec.ts',
  globalSetup: './test/browser/global-setup.mjs',
  timeout: 60_000,
  fullyParallel: false,
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL: `http://localhost:${port}`,
    viewport: { width: 640, height: 480 }
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: `node test/browser/server.mjs`,
    url: `http://localhost:${port}/pages/esm.html`,
    env: { PORT: String(port) },
    reuseExistingServer: false
  }
});
