# Cheese v2.5: Files (local iLovePDF-style tools)

This file **extends** `CLAUDE.md` (v1) and `CLAUDE-V2.md`. All earlier rules still apply. Where this file contradicts them, this file wins. Add `@CLAUDE-V2.5.md` to `CLAUDE.md` to load it automatically.

v2.5 adds a **Files** module: PDF tools, document ↔ PDF conversion, image tools and text-document conversion, **all fully offline**. No file ever leaves the Mac, and no network request is made at any point in this module.

---

## Principles

1. **Local only.** No network calls, no telemetry. WebViews used for rendering block every non-local load (see Rendering engine).
2. **Never touch the original.** Outputs are new files written **next to the original**. Nothing is overwritten.
3. **Small app.** The vendored JS renderers stay **under 3 MB total**. Don't bundle LibreOffice or any other large runtime.
4. **One engine by default, native apps optional.** The embedded engine is always the default. Microsoft Office or LibreOffice are used only if installed **and** the user turned on the fallback toggle.
5. **Every tool is a `FileTool`** registered in the v2 `ActionRegistry`, so Finder, the menu bar drop and the command palette all list the same tools.

---

## Entry points

### 1. Finder right-click: `Cheese ▸` submenu
- A new **Finder Sync extension** target (`CheeseFinderExtension`), sandboxed as Apple requires. `directoryURLs = ["/"]` so it applies everywhere.
- `menu(for: .contextualMenuForItems)` builds a `Cheese ▸` submenu containing **only the tools that apply to the current selection** (e.g. 2+ PDFs → Merge, Compress, Watermark…; images → Convert, Resize, Compress, Remove Background, Images → PDF). Logic lives in the shared, pure `ToolApplicability` (see below).
- **Handoff to the main app:** the extension writes a job file (`{tool, fileURLs}` JSON) into the shared **App Group** container (team-prefixed group ID `<TEAMID>.com.maanitgupta.cheese`, which needs no provisioning profile on macOS), then opens `cheese://job/<uuid>`. The main app (unsandboxed) reads the job, deletes the file and opens that tool's options panel.
- The user has to enable the extension in System Settings. Settings → Files shows its status, with a button calling `FIFinderSyncController.showExtensionManagementInterface()`. Mention it in the README.
- Add the target to `project.yml`. The extension contains **no tool logic**, only the menu and handoff.

### 2. Drop files on the menu bar icon
- The status item button accepts file drags (`.fileURL`). On drop, a menu pops up listing the tools that apply to the dropped files, grouped under **PDF**, **Convert** and **Images** headers. Choosing one opens its options panel.
- While dragging over the icon, highlight it.

### 3. Command palette
- Every tool appears as `Files: <Tool name>…` (e.g. "Files: Merge PDFs…").
- If **Finder is frontmost** when the palette opens, use the current Finder selection (fetched via AppleScript, which needs one-time Automation permission for Finder). If permission is denied or nothing is selected, show an `NSOpenPanel` filtered to the tool's accepted types.

No dedicated tool-grid window, and no new global hotkeys.

---

## Job flow

1. Entry point → **options panel** for the tool: a compact floating panel listing the input files (drag to reorder where order matters), the tool's options, and **Run**. The panel remembers the last-used options per tool (`UserDefaults`).
2. Run → the job goes to `JobQueue` (an actor; at most 2 jobs running concurrently, files within a job processed in order).
3. **Progress in the menu bar:** while jobs run, show `3/10` next to the icon. If keep-awake is also active, show both separated by `·` (e.g. `∞ · 3/10`). The menu gets a "Files: Merging 3 PDFs… — Cancel" item.
4. **Done:** a user notification (UserNotifications; ask permission the first time a job finishes) with a **Show in Finder** action. Partial failures list which files failed and why. A cancelled job removes its partial outputs.

### Output naming (`OutputNamer`: pure, unit-tested)
- Next to the original: `Report.pdf` → `Report (compressed).pdf`, `Report (merged).pdf` (named after the first file), `Report (pages 1-3).pdf`, `Report (watermarked).pdf`, `Report (numbered).pdf`, `Report (edited).pdf`. Conversions keep the base name with the new extension: `Report.docx`, `Photo.jpg`.
- Multi-file outputs go into a folder: `Report (images)/Report-001.png`.
- On collision, append ` 2`, ` 3`, and so on. **Never overwrite.**
- If the original's folder isn't writable, write to `~/Downloads` and say so in the notification.

---

## Tools

### PDF: organize
| Tool | Spec |
|---|---|
| **Merge** | 2+ PDFs, order set in the panel. PDFKit page insertion. Keep bookmarks/outlines where present (each source becomes a top-level outline entry). |
| **Split** | Modes: **ranges** (`1-3, 5, 8-` with a pure, unit-tested `PageRangeParser` that reports errors clearly), **every N pages**, **each page**. |
| **Page editor** | Its own window: thumbnail grid (`PDFThumbnailView` or a custom grid). Drag to reorder, rotate left/right, delete, multi-select (Shift/Cmd), **Extract selected** → new PDF, undo/redo, **Save** → `(edited)` copy. |

### PDF: compress (target size)
- The panel asks for a **target size** (MB). Prefill it with 50% of the original and show the original's size.
- Strategy, implemented in `PDFCompressor` with the search logic in a pure `CompressionPlanner`:
  1. Try PDFKit write options (`saveImagesAsJPEGOption`, `optimizeImagesForScreenOption`).
  2. If still above target: find **image-dominant pages** (`PDFImageInspector`, which scans content streams with `CGPDFScanner` for image XObjects covering most of the page), and re-render only those pages as JPEG at decreasing DPI/quality. Binary-search over (DPI 200 → 72, quality 0.8 → 0.4). **Text-only and vector pages stay vector.**
  3. Stop when under target, or at the floor.
- If the target can't be reached, save the smallest result and say "Couldn't reach 2 MB — smallest possible is 3.4 MB".
- If the output is **bigger** than the original, discard it and say so.
- `CompressionPlanner` takes an injectable "size of result for parameters" function, so the search is tested without real PDFs.

### PDF: edit
| Tool | Spec |
|---|---|
| **Watermark** | Text (font, size, color, opacity, rotation) **or** image (scale, opacity). Position: center, tiled, or one of 4 corners. Pages: all or a range. |
| **Page numbers** | Formats: `1`, `Page 1`, `1 / N`, `Page 1 of N`. Position: 6 options (top/bottom × left/center/right). Start number, skip first page, font size. |

Both use a shared `PDFOverlayRenderer`: draw each original page into a new `CGPDFContext` with `drawPDFPage`, then draw the overlay on top. This **preserves vector content and selectable text**. Never rasterize pages for these tools.

### Convert → PDF
| Input | Spec |
|---|---|
| **Images** (JPEG, PNG, HEIC, TIFF, GIF, BMP, WebP) | One image per page. Page size: **Fit to image** / A4 / Letter. Margins: none / small / normal. Orientation auto per image. Respect EXIF orientation. Multiple images → one PDF in panel order. |
| **Word (.docx)** | Embedded engine (docx-preview), see Rendering engine. |
| **Excel (.xlsx, .xls, .csv)** | Embedded engine (SheetJS CE → HTML tables). Each sheet starts on a new page. Landscape, fit to width. |
| **PowerPoint (.pptx)** | Embedded engine (vendored PPTX → HTML renderer), one slide per page at the slide's aspect ratio. |
| **HTML, Markdown, TXT** | `WebRenderer`. Markdown → HTML with vendored `marked`. TXT wrapped in `<pre>`. A clean default print stylesheet (`print.css`). Page size A4/Letter (default from locale). Paginated with `WKWebView.printOperation`. HTML files may load **relative local** resources from their own folder only, never remote ones. |

### Convert ← PDF
| Output | Spec |
|---|---|
| **Images** | PNG or JPEG, DPI 72 / 150 / 300, page range. Output into a `(images)` folder. |
| **Word (.docx)** | `PDFTextExtractor` takes text runs with font and position from PDFKit (`attributedString`, `characterBounds`). A pure `TextLayoutAnalyzer` groups lines into paragraphs (by vertical gaps), detects headings (font size relative to the page's median body size), keeps bold/italic, and detects simple bulleted lists. Each PDF page ends with a page break. Images are placed in reading order (found via `PDFImageInspector`, cropped by rendering that region) as attachments. Write `.docx` natively with `NSAttributedString` + `.officeOpenXML`. **Scanned pages** (no text layer) use Vision OCR line boxes instead. |
| **Excel (.xlsx)** | Words with bounding boxes → pure `TableDetector`: rows by y-clustering, columns by x-alignment and gaps. Numbers and dates parsed locale-aware into real numeric cells. One sheet per page (`Page 1`, `Page 2`…), or per detected table if a page has several. Write `.xlsx` with the **same vendored SheetJS running in `JavaScriptCore`** (`JSContext`, no WebView): `aoa_to_sheet` → `XLSX.write(type: "base64")`. Scanned pages → Vision OCR boxes. |

**Known limits (state them in the README, and in the panel as a one-line hint):** layout is approximate, multi-column pages may need manual cleanup, complex or merged-cell tables won't be perfect, and text inside images isn't converted unless the page is fully scanned.

### Images
| Tool | Spec |
|---|---|
| **Convert format** | Output PNG, JPEG, HEIC, TIFF, GIF (still), BMP, and **WebP only if** `CGImageDestinationCopyTypeIdentifiers()` includes it on this macOS (otherwise hide WebP as an output; it stays available as an input). ImageIO only. Preserve color profile and orientation. |
| **Resize** | Percentage, max width/height, or exact W×H with aspect lock. High-quality scaling (Core Image Lanczos or vImage). Pure `ResizeMath` for target dimensions. |
| **Compress** | Quality slider (JPEG/HEIC). **Strip metadata** (EXIF, GPS) toggle, **on by default**. Show before → after size. Keep the original if the result is bigger. |
| **Remove background** | Vision `VNGenerateForegroundInstanceMaskRequest` → PNG with transparency, fully on-device. If no subject is found, say so and write nothing. |

### Text documents
| Tool | Spec |
|---|---|
| **Markdown / HTML → DOCX** | Markdown → HTML (vendored `marked` in `JSContext`) → `NSAttributedString(html:)` (main thread, since it uses WebKit) → write `.officeOpenXML`. HTML input skips the first step. Headings, lists, bold/italic, links, code blocks (monospace) and simple tables should survive. |

---

## Rendering engine (embedded, default)

### Vendored JS
- Location: `Cheese/Resources/Renderers/`. Pin exact versions and record name, version, license and source URL in `Cheese/Resources/Renderers/VENDORED.md`. Include each license in the app's Acknowledgements (Settings → About).
- Libraries:
  - **docx-preview** (+ its JSZip dependency): Word → HTML pages
  - **SheetJS Community Edition** (`xlsx.full.min.js`): Excel/CSV read (→ HTML) and write (PDF → Excel)
  - **A PPTX → HTML renderer**: pick a maintained, permissively licensed (MIT/Apache/BSD) library. Compare 2 candidates on the fixture decks, record the choice and why in `VENDORED.md`, and ask the author before committing to it.
  - **marked**: Markdown → HTML
- Check total size in a unit test (`Renderers/` < 3 MB) so it can't silently grow.
- Licenses must be MIT-compatible (Cheese is MIT). Ask before vendoring anything copyleft.

### OfficeRenderer
- A hidden, offscreen `WKWebView` with a non-persistent data store, loading the bundled `office.html` via `loadFileURL(_:allowingReadAccessTo:)` scoped to `Renderers/`.
- **Network blocked:** install a `WKContentRuleList` that blocks all `http(s)` loads, and cancel any non-`file:` navigation in the navigation delegate. Documents with remote images render without them.
- Send document bytes in via `callAsyncJavaScript` (base64). The JS renders and posts `{pages: [{width, height}], ok}` back through a `WKScriptMessageHandler`.
- **Word / PowerPoint:** for each rendered page or slide element, `createPDF(configuration:)` with `rect` set to that element's frame, then merge the single-page PDFs with PDFKit.
- **Excel:** paginate with `printOperation(with:)` (landscape, fit to width) to a PDF file.
- Timeout: 60 s per document → fail that file with a clear error. Reuse one WebView per job, with a fresh page load per file.

### Known limits of the embedded engine (README + panel hint)
- **Word:** pagination is approximate. Long documents may break pages differently from Word. Complex floating layouts, SmartArt and embedded charts may be simplified.
- **Excel:** SheetJS CE gives **values, not styling**. Output is clean plain tables without cell colors or fonts. Charts aren't rendered.
- **PowerPoint:** the weakest fidelity. Animations, some shapes, SmartArt and embedded media aren't rendered.

### Optional native fallback
- Settings → Files → **"Use Microsoft Office or LibreOffice when available"**, **off by default**. The toggle only appears when one of them is detected (`NSWorkspace.urlForApplication(withBundleIdentifier:)`: `com.microsoft.Word`, `com.microsoft.Excel`, `com.microsoft.Powerpoint`, `org.libreoffice.script`).
- Applies to **Office → PDF only**.
  - LibreOffice: `soffice --headless --convert-to pdf --outdir <tmp> <file>` via `Process`, 120 s timeout.
  - Microsoft Office: AppleScript "save as PDF" through the matching app. This asks for macOS Automation permission once per app, and the app may launch visibly.
- If the fallback fails for any reason, **automatically retry with the embedded engine** and mention it in the notification.

---

## Shared pure logic (unit-tested)
`ToolApplicability` (UTTypes + file count → tools; shared by the extension and the app) · `OutputNamer` · `PageRangeParser` · `SplitPlanner` · `CompressionPlanner` · `TextLayoutAnalyzer` · `TableDetector` · `ResizeMath`.

Fixtures in `CheeseTests/Fixtures/Files/`: **self-made** sample PDFs (text, scanned, mixed, multi-column, tables), DOCX/XLSX/PPTX and images (including HEIC with EXIF/GPS). No third-party or copyrighted documents.

Integration tests (can be slower, behind a `FILES_INTEGRATION` flag): render each Office fixture to PDF and assert page count > 0 with extractable text. Round-trip PDF → DOCX → check headings exist.

---

## Architecture additions

```
Cheese/
  Files/
    Core/         FileTool, FileToolRegistry, ToolApplicability, JobQueue, Job,
                  OutputNamer, OptionsPanel, StatusItemDropHandler, JobNotifications
    PDF/          MergeTool, SplitTool, SplitPlanner, PageRangeParser, PageEditor/,
                  CompressTool, PDFCompressor, CompressionPlanner, PDFImageInspector,
                  WatermarkTool, PageNumbersTool, PDFOverlayRenderer
    Convert/      ImagesToPDFTool, PDFToImagesTool, OfficeToPDFTool, OfficeRenderer,
                  WebToPDFTool, WebRenderer, PDFToDocxTool, PDFToXlsxTool,
                  PDFTextExtractor, TextLayoutAnalyzer, TableDetector, SheetJSWriter
    Images/       ConvertImageTool, ResizeImageTool, CompressImageTool,
                  RemoveBackgroundTool, ResizeMath
    TextDocs/     MarkdownToDocxTool
    Fallback/     NativeAppDetector, LibreOfficeBridge, MicrosoftOfficeBridge
  Resources/Renderers/   office.html, print.css, vendored JS, VENDORED.md
CheeseFinderExtension/   FinderSync.swift (menu + App Group handoff only)
```

The **Files** module joins the v2 module toggles. When disabled: no drop handling on the icon, no palette entries, the Finder extension shows a single disabled "Cheese Files is turned off" item, and nothing runs.

## Permissions added in v2.5
- Notifications: first job completion
- Automation → Finder: only for palette + Finder selection
- Automation → Word/Excel/PowerPoint: only if the native fallback is on and used
- Finder extension: user enables it in System Settings

## Build order (v2.5)
1. Files core: `FileTool`, registry, `ToolApplicability`, `JobQueue`, `OutputNamer`, options panel, menu bar drop, progress + notifications. Ship with one trivial tool (Images → Convert) to prove the pipeline end to end.
2. PDF organize: merge, split, page editor
3. Images: resize, compress, remove background; Images → PDF; PDF → images
4. `PDFOverlayRenderer` → watermark + page numbers
5. Compress (target size): `CompressionPlanner` tests first
6. `WebRenderer`: HTML/Markdown/TXT → PDF; Markdown/HTML → DOCX
7. `OfficeRenderer`: Word → PDF, then Excel, then PowerPoint (renderer choice confirmed with the author first)
8. PDF → Word, then PDF → Excel (`TextLayoutAnalyzer` / `TableDetector` tests first)
9. Finder Sync extension + App Group handoff
10. Command palette integration (Finder selection + file picker); native Office/LibreOffice fallback

End each step with the author's manual checklist: real-world files (a long Word report, a multi-sheet Excel file, a 30-slide deck, a scanned PDF, an iPhone HEIC), Finder menu on different selections, very large files (200+ page PDF, 50 MB image), and cancel mid-job.

## Out of scope for v2.5
OCR-to-searchable PDF, PDF repair, protect/unlock, sign, redact, metadata editing, PDF → text/Markdown, audio/video conversion, Markdown ↔ HTML, DOCX ↔ RTF/TXT, DOCX → Markdown, tool-grid window, Excel cell styling, native fallback for PDF → Office, any cloud or network processing.
