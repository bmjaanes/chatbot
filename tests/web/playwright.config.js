// Browser tests for the Next Time web app (docs/index.html and docs/share.html).
// Run from this folder: npm ci && npx playwright test
const { defineConfig, devices } = require("@playwright/test");

const PORT = 8765;

module.exports = defineConfig({
  testDir: "./specs",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: {
    baseURL: `http://127.0.0.1:${PORT}/`,
    // Phone-sized, like the iPhones people use the web app on.
    ...devices["Desktop Chrome"],
    viewport: { width: 390, height: 844 },
    permissions: ["clipboard-read", "clipboard-write"],
    trace: "retain-on-failure",
  },
  webServer: {
    command: `python3 -m http.server ${PORT} --bind 127.0.0.1 --directory ../../docs`,
    url: `http://127.0.0.1:${PORT}/index.html`,
    reuseExistingServer: !process.env.CI,
    stdout: "ignore",
    stderr: "ignore",
  },
});
