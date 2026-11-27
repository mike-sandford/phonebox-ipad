const { test, expect } = require('@playwright/test');

// The settings page names the panel "the phone". With a Mac agent and only the iPad app seen, the English texts say
// "Mac" and "iPad" instead, keep "phone" where a text is about an Android-only feature, and the pairing dialog keeps the
// Android app download behind a button.

async function openAs(page, { os, models }) {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto('/panel/style.css');
  await page.evaluate(() => localStorage.clear());
  await page.goto('/settings/#general');
  await page.waitForFunction(() => cfg?.display && typeof loadPhones === 'function');
  await page.evaluate(async ({ os, models }) => {
    const demoFetch = window.fetch;
    window.fetch = async (input, init) => {
      const url = String(input?.url ?? input);
      if (url.includes('/api/info')) {
        const info = await (await demoFetch(input, init)).json();
        return new Response(JSON.stringify({ ...info, os }), { headers: { 'Content-Type': 'application/json' } });
      }
      if (url.includes('/api/phones')) {
        return new Response(JSON.stringify(models.map((model, i) => ({ id: 'dev' + i, model, lastSeen: Date.now(), via: 'Wi-Fi' }))),
          { headers: { 'Content-Type': 'application/json' } });
      }
      return demoFetch(input, init);
    };
    await loadInfo();
    await loadPhones();
  }, { os, models });
}

test('an iPad panel on a Mac: the settings say iPad and Mac', async ({ page }) => {
  await openAs(page, { os: 'macos', models: ['Apple iPad7,11'] });
  await expect(page.locator('#openPhone')).toHaveText('Open on iPad');
  await expect(page.locator('#phone span')).toHaveText(/^iPad connected/);
  await expect(page.locator('#lanPair')).toHaveText('Pair a phone or iPad over Wi-Fi');
  const texts = await page.evaluate(() => ['s.wh.lanHint', 's.display.volumeKeys', 's.pages.screen.phone', 's.js.runHint']
    .map((k) => window.PhoneBoxI18n.t(k)));
  expect(texts[0]).toContain("this Mac's");
  expect(texts[1]).toBe("The phone's volume keys switch pages"); // Android only: stays a phone
  expect(texts[2]).toBe('Phone'); // the editor's phone screen size
  expect(texts[3]).toContain('on Windows'); // about Windows: keeps its words, but the panel is still the iPad
  expect(texts[3]).toContain('on the iPad');

  await page.evaluate(() => pairOverWifi());
  await expect(page.locator('#modal .pair-qr').first()).toBeHidden();
  await expect(page.locator('#modal .pair-qr').nth(1)).toContainText('Scan this with the iPad’s camera');
  await page.getByRole('button', { name: 'Pairing an Android phone? Show its app download' }).click();
  await expect(page.locator('#modal .pair-qr').first()).toBeVisible();
});

test('Android phones keep the phone wording and the app download', async ({ page }) => {
  await openAs(page, { os: 'windows', models: ['Apple iPad7,11', 'UMIDIGI BISON'] });
  await expect(page.locator('#openPhone')).toHaveText('Open on phone');
  await page.evaluate(() => pairOverWifi());
  await expect(page.locator('#modal .pair-qr').first()).toBeVisible();
  await expect(page.getByRole('button', { name: /Show its app download/ })).toHaveCount(0);
});
