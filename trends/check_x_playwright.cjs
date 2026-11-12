'use strict';
// Invoke as a file, NOT with "node -e" from Windows PowerShell 5.1: its
// argument quoting can turn require("playwright") into require(playwright).
const playwright = require('playwright');
if (!playwright || !playwright.chromium || typeof playwright.chromium.launch !== 'function') {
  throw new Error('Playwright Chromium API unavailable');
}
console.log('TT_X_PLAYWRIGHT_MODULE_OK');
