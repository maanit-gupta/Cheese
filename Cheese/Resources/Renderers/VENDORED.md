# Vendored renderers

Third-party JavaScript bundled with Cheese for the offline Files tools. Every file is pinned to an
exact version, copied unmodified from the published package, and loaded only from the app bundle:
the web views that run them block every non-local load. The whole `Renderers/` folder must stay
under 3 MB (`RendererBudgetTests` enforces it). Each license is in `licenses/` and shown in
Settings → About.

| File | Library | Version | License | Source |
|---|---|---|---|---|
| `marked.umd.js` | marked | 18.1.1 | MIT | https://www.npmjs.com/package/marked/v/18.1.1 (`lib/marked.umd.js`) |
| `jszip.min.js` | JSZip | 3.10.2 | MIT (dual MIT/GPLv3; used under MIT) | https://www.npmjs.com/package/jszip/v/3.10.2 (`dist/jszip.min.js`) |
| `docx-preview.min.js` | docx-preview | 0.4.1 | Apache-2.0 | https://www.npmjs.com/package/docx-preview/v/0.4.1 (`dist/docx-preview.min.js`) |
| `xlsx.full.min.js` | SheetJS Community Edition | 0.20.3 | Apache-2.0 | https://cdn.sheetjs.com/xlsx-0.20.3/xlsx-0.20.3.tgz (`dist/xlsx.full.min.js`) |
| `pptx-to-html.js` | @jvmr/pptx-to-html | 1.1.2 | MIT | https://www.npmjs.com/package/@jvmr/pptx-to-html/v/1.1.2 (`dist/index.js`) |

`office.html`, `office.js` and `print.css` are Cheese's own.

Sizes: SheetJS 952 KB, pptx-to-html 103 KB, JSZip 98 KB, docx-preview 76 KB, marked 48 KB.

## Notes

- SheetJS is published on its own CDN, not npm (the npm `xlsx` package is stuck at 0.18.5).
- `pptx-to-html.js` is an ES module that does `import JSZip from "jszip"`. `OfficeRenderer` runs it as a
  classic script by swapping that import for the `JSZip` global and its `export` for a `window`
  property at load time; the file on disk stays byte-for-byte as published.

## Choosing the PowerPoint renderer

Two maintained, permissively labelled PPTX → HTML libraries were compared against
`CheeseTests/Fixtures/Files/deck.pptx` (a title slide, a bulleted slide, and a slide with a shape and a
table):

| | pptx-preview 1.0.7 | @jvmr/pptx-to-html 1.1.2 |
|---|---|---|
| License | `ISC` in package.json, but the README restricts the code to personal study, forbids republishing it, and the source is closed (paid on request) | MIT, source on GitHub |
| Size | 1.36 MB UMD bundle (echarts, lodash and JSZip inside) | 103 KB, plus the JSZip Cheese already ships |
| Output | Renders into a container through its own previewer | One self-contained HTML snippet per slide at the deck's aspect ratio |
| Renders | Text, shapes, images, tables, charts | Text, bullets, shapes, images, tables, common charts |

**Chosen: @jvmr/pptx-to-html.** pptx-preview's terms conflict with redistributing it in an
MIT-licensed public repository whatever its package.json says, so it was ruled out before a rendering
comparison; it would also have used almost half the 3 MB budget. pptx-to-html renders every fixture
slide with selectable text at 16:9 (`OfficeRenderingIntegrationTests`).

## Updating

1. Download the package (`npm pack <name>@<version>`) into a scratch folder, never into the repo.
2. Copy the file listed above, unmodified, and replace its license in `licenses/`.
3. Update the version here and in `Acknowledgements` (Settings → About), then run `make test-integration`.

Only MIT-compatible licenses (MIT, BSD, ISC, Apache-2.0). Ask before adding anything copyleft.
