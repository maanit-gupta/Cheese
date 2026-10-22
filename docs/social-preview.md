# GitHub social preview (1280 × 640)

The image GitHub shows when the repo is linked on social sites. Make it from this spec, export it as
PNG under 1 MB, and upload it in the repo's **Settings → General → Social preview**.

## Layout

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  80 px margin on every side                                                    │
│                                                                                │
│   ┌────────┐                                                                   │
│   │  icon  │   Cheese                                                          │
│   │ 200 px │   The Swiss Army knife for your Mac.                              │
│   └────────┘   Every little tool your Mac forgot.                              │
│                                                                                │
│   ───────────────────────────────────────────────────────────────────          │
│   Copy · Capture · Draw · Convert · Share · Control                            │
│                                                                                │
│                         Free · Local · Open source        github.com/maanit-gupta/Cheese │
└──────────────────────────────────────────────────────────────────────────────┘
```

- **Icon:** the app icon (`docs/media/icon.png`) at 200 × 200, top-left inside the margin, with the
  icon's own shadow. Don't recolor or redraw it, and don't put a knife or Swiss cross on or near it.
- **Name:** "Cheese", SF Pro Display Bold, 96 pt, left-aligned 48 px right of the icon, baseline level
  with the icon's vertical center.
- **Tagline:** "The Swiss Army knife for your Mac.", SF Pro Display Semibold, 44 pt, under the name.
- **Subline:** "Every little tool your Mac forgot.", SF Pro Display Regular, 32 pt, 70 % opacity.
- **Rule:** 2 px line at 15 % opacity across the content width, 56 px under the subline.
- **Verbs:** "Copy · Capture · Draw · Convert · Share · Control", SF Pro Text Medium, 34 pt, each verb
  preceded by its SF Symbol at the same size (`doc.on.clipboard`, `camera.viewfinder`,
  `pencil.and.scribble`, `arrow.triangle.2.circlepath`, `square.and.arrow.up`, `slider.horizontal.3`).
- **Footer:** "Free · Local · Open source" bottom-left and `github.com/maanit-gupta/Cheese` bottom-right,
  SF Pro Text Regular, 26 pt, 60 % opacity.

## Colors

| Element | Color |
|---|---|
| Background | Vertical gradient from `#FFD84D` (top) to `#FFB81C` (bottom), the icon's cheese yellows |
| Text, rule, symbols | `#1D1D1F` |
| Optional texture | The icon's cheese holes as 3–4 large circles at 6 % black opacity, bottom-right, clear of the text |

## Rules
- "Swiss Army" appears **only** in the tagline text. Never in a logo, badge or image.
- No feature counts ("10-in-1", "11 tools", and so on).
- No screenshots: at thumbnail size they turn into noise. The verbs say what Cheese does.
- Keep everything 40 px clear of the edges, since some sites crop to 1200 × 630.
