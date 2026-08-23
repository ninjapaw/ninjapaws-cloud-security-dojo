const { defineConfig, devices } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests/e2e',
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? 'line' : 'list',
  use: { baseURL: 'http://127.0.0.1:4326', trace: 'retain-on-failure', screenshot: 'only-on-failure' },
  webServer: { command: 'node app.js', url: 'http://127.0.0.1:4326/health', reuseExistingServer: !process.env.CI, timeout: 120000, env: { PORT: '4326' } },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'mobile-chromium', use: { ...devices['Pixel 5'] } }
  ]
});