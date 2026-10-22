import { chromium } from 'playwright-core';
import { mkdirSync } from 'node:fs';
import { readdirSync } from 'node:fs';
const cache = process.env.HOME + '/Library/Caches/ms-playwright';
const latest = readdirSync(cache).filter(d => /^chromium-\d+$/.test(d)).sort().pop();
const exe = process.env.CHROMIUM ?? `${cache}/${latest}/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const [mode, ...rest] = process.argv.slice(2);
const browser = await chromium.launch({ executablePath: exe });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
await page.goto('file://' + process.cwd() + '/promo.html');
await page.waitForLoadState('networkidle');
await page.evaluate(() => document.fonts.ready);
if (mode === 'stills') {
  mkdirSync('stills', { recursive: true });
  for (const t of rest.map(Number)) {
    await page.evaluate(t => window.seek(t), t);
    await page.screenshot({ path: `stills/t${String(t).padStart(5, '0')}.png` });
  }
} else {
  const fps = Number(rest[0] || 30);
  mkdirSync('frames', { recursive: true });
  const dur = await page.evaluate(() => window.DURATION);
  const n = Math.round(dur * fps);
  for (let i = 0; i < n; i++) {
    await page.evaluate(t => window.seek(t), i / fps);
    await page.screenshot({ path: `frames/f${String(i).padStart(5, '0')}.png` });
    if (i % 150 === 0) console.log(`frame ${i}/${n}`);
  }
}
await browser.close();
