# Cheese design language (CheeseUI)

Cheese's look wasn't designed up front. It grew screen by screen. This file records what those
screens already do, and the tokens and components in `Cheese/CheeseUI/` that came out of it. All
new UI uses CheeseUI components and system SF Symbols only, with no one-off styling.

## Audit (before v3)

| Screen | Container | Corner radius | Material | Padding / spacing | Fonts | Buttons | Icons |
|---|---|---|---|---|---|---|---|
| Clipboard popover (`HistoryView`, `HistoryPreview`) | `NSPopover` under the menu bar icon | rows 6, thumbnails 3 | popover default | header 12×10, list 6, rows 8×5, preview 12–16 | `.title3` search, `.caption` metadata, `.caption.monospacedDigit` index | none (keyboard driven) | SF Symbols per kind, 20 pt |
| Capture overlay (`SelectionOverlay`, `WindowPicker`) | borderless full-screen windows | none | dimmed screenshot | n/a | system label in the size badge | none | crosshair cursor |
| Annotation editor (`AnnotationEditorView`) | standard titled window | color swatch 3 | window background | toolbar 12×8, spacing 12 | `.system(size:)` toolbar glyphs | segmented tool picker, bordered Copy/Save | SF Symbols |
| Scroll preview (`ScrollPreviewWindow`) | standard titled window | none | window background | toolbar 12×8, spacing 10 | `.callout` status | bordered, `.small` | none |
| Scroll HUD (`ScrollCaptureHUD`) | floating panel | 12 | `.regularMaterial` | 16×10, spacing 12 | `.headline` + `.caption` | `.borderedProminent`, `.small` | none |
| QR panel (`QRPanel`) | `FloatingPanel` (now `CheesePanel`) | panel 18, quiet zone 12 | `.regularMaterial` | 20, spacing 14 / 8 / 4 | `.title3.semibold` title, `.callout` preview, `.caption` status | plain bordered Close / Stop Sharing | 40 pt message symbol |
| Command palette (`PalettePanel`) | `FloatingPanel` (now `CheesePanel`) | panel 16, rows 8 | `.regularMaterial` | search 16×14, list 6, rows 10×7, spacing 10 / 2 | `.title2` search, rounded `.callout` shortcut | none (keyboard driven) | SF Symbols, 22 pt column |
| Draw toolbar (`ToolbarPanel`) | non-activating `NSPanel` | rail 12, buttons 7, swatch rings circular, collapsed pill capsule | `.regularMaterial` | rail 4×6, buttons 32×27, flyout 12 | `.system(size: 15)` glyphs, `.caption` flyout labels | `.plain` with 0.28 accent tint when active | SF Symbols |
| Radial menu (`RadialMenuLayer`) | Core Animation layers in the overlay | disc | dark disc, 0.35 shadow | n/a | system | slices | emoji + SF Symbols |
| Files options panel (`OptionsPanel`) | titled utility panel | none | window background | 12, spacing 8 | `.callout` hint, `.caption` labels | `.borderless` remove, default Run | file icons 20 pt |
| Page editor (`PageEditorTool`) | titled window | thumbnails 8 | window background | grid 20, spacing 18, cells 6 | `.caption` page numbers | `.borderedProminent` Save, `.small` | SF Symbols |
| Toast (`Toast`, now `CheeseToast`) | non-activating panel | capsule | `.regularMaterial` | 16×10, spacing 10 | `.title3` symbol, `.body.medium` text | `.borderedProminent`, `.small` | SF Symbols |
| Settings (`SettingsView` tabs) | SwiftUI `Settings` window, `Form` `.grouped` | system | system | system | `.caption` footnotes, `.title` About name | system | SF Symbols in tab items |
| Welcome guide (`WelcomeView`) | titled window 620×580 | keycaps 6 | window background | 48 sides, 36 top, spacing 24 / 10 / 6 | `.title.bold` page title, `.headline` + `.callout` rows | default / `.borderedProminent` | SF Symbols 32 pt, app icon 72 pt |
| Time picker (`TimePickerView`) | small panel | system | window background | 20, spacing 14 | `.headline`, `.caption` | default | none |

### What was consistent
- **Floating surfaces** (toast, palette, QR, HUD, draw rail): `.regularMaterial`, rounded, system shadow.
- **Selected rows**: solid accent fill, white text, grey text at 75 % white (palette, history).
- **Active tools**: accent tint at about 0.25 behind the glyph, glyph in accent color.
- **Spacing** clusters on 2, 4, 6, 8, 10, 12, 16, 20 and 24.
- **Fonts**: system text styles only. `.headline` for small headings, `.callout` for secondary text,
  `.caption` for metadata, rounded design for keycaps.
- **Icons**: SF Symbols everywhere except the radial menu's emoji stamps.

### What drifted
- Panel corner radius: palette 16, QR 18. Standardised on **16**.
- Row radius: history 6, palette 8. Standardised on **8** for rows, **6** for keycaps and swatches.
- Rail button hit area: 32×27 in the draw rail vs 28×26 elsewhere. CheeseUI uses **28×26**; the rail keeps 32×27 because it's a touch-sized drawing tool.
- Reduce Transparency was ignored everywhere. CheeseUI swaps the material for the window color.
- Reduce Motion was handled only by draw mode. CheeseUI's panels and animations honor it.

## Tokens (`DesignTokens`)

| Token | Values |
|---|---|
| Spacing | hairline 2 · xxSmall 4 · xSmall 6 · small 8 · medium 10 · large 12 · xLarge 16 · xxLarge 20 · xxxLarge 24 · panel 14 (inside a panel's edge) |
| Radius | small 6 (keycaps, swatches) · row 7 (list rows, device tiles) · medium 8 (search fields, thumbnails) · card 10 (cards in panels) · large 12 (HUDs, rail, QR quiet zone) · panel 14 |
| Typography | panelTitle `.title3.semibold` · pageTitle `.title.bold` · heading `.headline` · body · secondary `.callout` · caption · searchField `.title2` · keycap rounded `.callout` · numeric monospaced `.callout` · code monospaced `.caption` |
| Material | `.regularMaterial` with a 1 pt `primary` 0.09 inner border; with Reduce Transparency, `windowBackgroundColor` |
| Opacity | active tint 0.25 · selected row tint 0.18 · hover tint 0.06 · panel border 0.09 |
| Size | icon button 28×26 · row icon 22 · thumbnail row 44 with a 28 pt thumbnail · selection bar 2 · empty-state symbol 40 · large symbol 28 |
| Duration | quick 0.12 s · standard 0.15 s · gentle 0.25 s; zero with Reduce Motion |

## Components

| Component | Use it for | Extracted from |
|---|---|---|
| `CheesePanel` | Every floating popup: non-activating, takes keys, Esc / outside click closes, placement centered, near the pointer, or remembered | `FloatingPanel` (palette, QR) |
| `CheeseToast` | Brief confirmations with one optional action | `Toast` |
| `CheeseCard` | Tiles: shelf items, device tiles, welcome tool groups | history preview, page editor thumbnails |
| `CheeseListRow` + `CheeseKeycap` | Rows with symbol, title, grey detail, trailing shortcut; a 0.06 hover fill that never shifts layout | palette row, welcome shortcut rows |
| `CheeseIconButton` | Toolbar glyph buttons with tooltip and active tint | draw rail buttons |
| `CheeseToolbar` | A row of controls along a panel edge | editor / scroll preview toolbars |
| `CheeseSectionHeader` | Headings over groups | settings and welcome headings |
| `CheeseSectionCaps` | Small-capital group labels inside compact panels (PDF, CONVERT, NEARBY DEVICES) | v4 drop hub |
| `CheeseDivider` | The 1 pt separator-colored rule between a panel's parts, horizontal or vertical | clipboard popover's column rule |
| `CheeseTextButtonStyle` | Small tinted text buttons like Clear and Stop, with a hover fill | v4 Share panel |
| `CheeseDropHostView` | An AppKit drop target around a panel's SwiftUI content | the shelf (fix pass) |
| `CheeseEmptyState` | Empty and error states | QR panel messages, empty history |
| `.cheesePanelBackground()` / `.cheeseSurface(in:)` | Material backgrounds that honor Reduce Transparency | every floating surface |
| `PermissionNeedRow` | A permission, the tools that need it, live status and Grant | welcome screen and Settings → Permissions |
| `DesignTokens.Overlay` | Badge background and fonts for AppKit-drawn overlays | capture overlay, radial menu |

## Migration status

Every screen in the audit above now uses CheeseUI: tokens and components for SwiftUI screens, and
`DesignTokens.Overlay`, the radii, the accent tint and the durations for the AppKit and Core Animation
overlays (capture overlay, window picker, radial menu). Each move is its own commit listing what
visibly changed. The new v3 screens (welcome, Shelf, Share panel, receive prompt, Settings → Share)
were built on CheeseUI from the start.

The clipboard popover was reworked after that (fix pass): a fixed 680×460 split with a 280 pt list
column (search field in a `.quaternary` capsule, 44 pt rows, 28 pt thumbnails cropped to their square,
selection as a 0.18 accent tint with a 2 pt accent bar) and a preview pane with a header, clipped
content and a shortcut footer.

## v4 polish pass

Panels got tighter, crisper edges and one hover language:
- Panel radius 16 → 14, cards 12 → 10, list rows 8 → 7; content sits 14 pt inside a panel's edge.
- Every `cheesePanelBackground()` adds a 1 pt `primary` 0.09 inner border, so panels stay defined on
  busy wallpapers in light and dark.
- `CheeseListRow` and `CheeseIconButton` fade in a 0.06 `primary` fill on hover over 0.12 s (none with
  Reduce Motion), drawn as a background so nothing moves.
- Clipboard history, the Shelf, the Files options panel, Auto-Kill and the palette now separate their
  parts with `CheeseDivider`; the palette's search font and padding and the shelf's large symbols are tokens.
- New v4 surfaces (drop hub, Share panel, QR panel) use only these components.

## Rules
1. v3 UI uses only CheeseUI components and SF Symbols.
2. Don't add a literal padding, radius, font or color in a view. If a token is missing, add it to
   `DesignTokens` and note why here.
3. Older screens move to CheeseUI one screen per commit, and each commit message lists what visibly changed.
