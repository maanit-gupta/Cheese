// Renders promo.html, which is a pure function of time (window.seek(t)), so every render is identical.
//   node render.mjs stills 6.5 21.5     spot-check frames → stills/
//   node render.mjs video 30            PNG frames → frames/ (START=<frame> resumes)
//   node render.mjs mp4 30 out.mp4      frames piped straight into ffmpeg (no frames on disk)
// SCALE (default 2) renders at SCALE × 1920×1080 so text and edges stay crisp after downscaling;
// OUT_W×OUT_H (default 2560×1440) is the mp4's size. CHROMIUM overrides the browser binary.
import { chromium } from 'playwright-core';
import { mkdirSync, readdirSync } from 'node:fs';
import { spawn } from 'node:child_process';
const cache = process.env.HOME + '/Library/Caches/ms-playwright';
const latest = readdirSync(cache).filter(d => /^chromium-\d+$/.test(d)).sort().pop();
const exe = process.env.CHROMIUM ?? `${cache}/${latest}/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const scale = Number(process.env.SCALE || 2);
const [mode, ...rest] = process.argv.slice(2);
const browser = await chromium.launch({ executablePath: exe });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: scale });
page.on('pageerror', e => { console.error('page error:', e.message); process.exitCode = 1; });
await page.goto('file://' + process.cwd() + '/promo.html');
await page.waitForLoadState('networkidle');
await page.evaluate(() => document.fonts.ready);
const dur = await page.evaluate(() => window.DURATION);

if (mode === 'stills') {
  mkdirSync('stills', { recursive: true });
  for (const t of rest.map(Number)) {
    await page.evaluate(t => window.seek(t), t);
    await page.screenshot({ path: `stills/t${String(t).padStart(5, '0')}.png` });
  }
} else if (mode === 'mp4') {
  const fps = Number(rest[0] || 30), out = rest[1] || '../../docs/media/cheese-promo.mp4';
  const w = Number(process.env.OUT_W || 2560), h = Number(process.env.OUT_H || 1440);
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-',
    '-vf', `scale=${w}:${h}:flags=lanczos`, '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '18', '-preset', 'slow',
    '-tune', 'animation', '-movflags', '+faststart', out], { stdio: ['pipe', 'inherit', 'inherit'] });
  const done = new Promise((ok, fail) => ff.on('close', c => c === 0 ? ok() : fail(new Error('ffmpeg exited ' + c))));
  const n = Math.round(dur * fps);
  for (let i = 0; i < n; i++) {
    await page.evaluate(t => window.seek(t), i / fps);
    const jpg = await page.screenshot({ type: 'jpeg', quality: 95 });
    if (!ff.stdin.write(jpg)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % 150 === 0) console.log(`frame ${i}/${n}`);
  }
  ff.stdin.end();
  await done;
  console.log(`wrote ${out} (${n} frames, ${dur} s)`);
} else {
  const fps = Number(rest[0] || 30);
  mkdirSync('frames', { recursive: true });
  const n = Math.round(dur * fps);
  // START resumes a long render after a hiccup; frames are deterministic, so they match.
  for (let i = Number(process.env.START || 0); i < n; i++) {
    await page.evaluate(t => window.seek(t), i / fps);
    await page.screenshot({ path: `frames/f${String(i).padStart(5, '0')}.png` });
    if (i % 150 === 0) console.log(`frame ${i}/${n}`);
  }
}
await browser.close();
