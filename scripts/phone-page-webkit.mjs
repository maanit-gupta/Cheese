// Drives Cheese Share's phone page in WebKit (Safari's engine) as an iPhone 13, against the real server
// started by the PhonePageInBrowserTests test. See docs/DEVELOPMENT.md.
import { webkit, devices } from '../Design/promo/node_modules/playwright-core/index.mjs';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
const dir = process.argv[2];
for (let i = 0; i < 600 && !existsSync(dir + '/url.txt'); i++) await new Promise(r => setTimeout(r, 200));
const url = readFileSync(dir + '/url.txt', 'utf8');
const browser = await webkit.launch();
const context = await browser.newContext({ ...devices['iPhone 13'], acceptDownloads: true });
const page = await context.newPage();
const errors = [];
page.on('pageerror', e => errors.push(String(e)));
await page.goto(url);
const file = dir + '/photo with spaces.jpg';
writeFileSync(file, Buffer.alloc(30000, 7));
await page.setInputFiles('#files', file);
await page.waitForSelector('text=Sent to Mac ✓', { timeout: 10000 });
await page.fill('#text', 'hello from the phone');
await page.click('#sendText');
await page.waitForSelector("text=Sent — it’s on your Mac’s clipboard ✓", { timeout: 10000 });
await page.waitForSelector('text=From Mac.txt', { timeout: 10000 });
const [download] = await Promise.all([page.waitForEvent('download'), page.click('a.cta')]);
const downloaded = readFileSync(await download.path(), 'utf8');
const shown = await page.textContent('#mac .txt');
await page.click('[data-copy]');
const copied = await page.textContent('[data-copy]');
await page.screenshot({ path: dir + '/webkit.png' });
await page.emulateMedia({ colorScheme: 'dark' });
await page.waitForTimeout(400); // let the drop zone's colour transition finish
await page.screenshot({ path: dir + '/webkit-dark.png' });
console.log(JSON.stringify({ engine: 'webkit ' + browser.version(), downloaded, suggestedName: download.suggestedFilename(), shown, copied, errors }));
writeFileSync(dir + '/done', '');
await browser.close();
