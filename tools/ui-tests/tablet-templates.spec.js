const { test, expect } = require('@playwright/test');

// templates.json may give a template a 12 × 10 "tablet" layout (a 4:3 tablet such as an iPad). The editor uses it on
// the Tablet screen with More rows on a tablet on, and the 12 × 6 layout everywhere else.

async function openPicker(page, { tabletRows, screen }) {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto('/panel/style.css');
  await page.evaluate(({ tabletRows, screen }) => {
    localStorage.clear();
    localStorage.setItem('pb-editor-screen', screen);
    localStorage.setItem('pb-demo-config', JSON.stringify({ night: { enabled: false }, shortcuts: [],
      display: { idleReturnSec: 0, tabletRows }, pages: [{ id: 'one', title: 'One', enabled: true, widgets: [] }] }));
  }, { tabletRows, screen });
  await page.goto('/settings/#pages');
  // the settings and the catalog arrive separately; the picker needs both
  await page.waitForFunction(() => cfg?.display && catalog.templates.some((t) => t.tablet));
  await page.evaluate(() => openTemplates(null));
  await expect(page.locator('#modal')).toBeVisible();
}

const pickHome = async (page) => {
  await page.locator('#modal .tpl').nth(1).click(); // the first template (Home) comes after "Blank page"
  return page.evaluate(() => {
    const widgets = cfg.pages[cfg.pages.length - 1].widgets;
    return { count: widgets.length, bottom: Math.max(...widgets.map((w) => w.y + w.h)) };
  });
};

test('the Tablet screen offers and uses the 12 x 10 layout of a template', async ({ page }) => {
  await openPicker(page, { tabletRows: true, screen: 'tablet' });
  await expect(page.locator('#modal .tpl').nth(1).locator('.mini')).toHaveClass(/mini-tall/);
  expect(await pickHome(page)).toEqual({ count: 8, bottom: 10 });
});

test('the Phone screen keeps the 12 x 6 layout', async ({ page }) => {
  await openPicker(page, { tabletRows: true, screen: 'phone' });
  await expect(page.locator('#modal .tpl').nth(1).locator('.mini')).not.toHaveClass(/mini-tall/);
  expect(await pickHome(page)).toEqual({ count: 6, bottom: 6 });
});

test('without More rows on a tablet the Tablet screen keeps the 12 x 6 layout', async ({ page }) => {
  await openPicker(page, { tabletRows: false, screen: 'tablet' });
  expect(await pickHome(page)).toEqual({ count: 6, bottom: 6 });
});

test('the Wide tablet screen (12 x 8) keeps the 12 x 6 layout', async ({ page }) => {
  await openPicker(page, { tabletRows: true, screen: 'wide' });
  expect(await pickHome(page)).toEqual({ count: 6, bottom: 6 });
});
