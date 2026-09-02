const { expect, test } = require('@playwright/test');

test('renders the Cloud Security Dojo training surface', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveTitle(/Cloud Security Dojo/i);
  await expect(page.getByRole('heading', { name: /Cloud Security Dojo/i })).toBeVisible();
  await expect(page).toHaveURL(/127\.0\.0\.1/);
});