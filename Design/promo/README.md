# Promo video

`promo.html` is a deterministic animation: `window.seek(t)` draws the frame at time `t`, so every render is identical.

```sh
cd Design/promo
npm install --no-save playwright-core && npx playwright install chromium
node render.mjs stills 6.5 21.5        # spot-check frames → stills/
node render.mjs video 30               # 1,500 frames → frames/
ffmpeg -framerate 30 -i frames/f%05d.png -c:v libx264 -pix_fmt yuv420p -crf 20 -preset slow -movflags +faststart ../../docs/media/cheese-promo.mp4
ffmpeg -i ../../docs/media/cheese-promo.mp4 -vf "fps=12,scale=880:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" ../../docs/media/cheese-promo.gif
```

`render.mjs` looks for Playwright's Chromium in `~/Library/Caches/ms-playwright`; set `CHROMIUM` to use another binary.
