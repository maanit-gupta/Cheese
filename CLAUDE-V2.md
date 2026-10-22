# Cheese v2: spec

This file **extends** `CLAUDE.md` (v1). Every v1 rule still applies: stack, architecture rules, signing, commands, zero warnings, tests, and the manual test checklist for the author. Where this file contradicts v1, this file wins. To load it automatically, add the line `@CLAUDE-V2.md` to `CLAUDE.md`.

v2 adds six things:
1. **Action registry + module toggles**: groundwork for everything else
2. **Draw on screen**: Miro-style annotation overlay with a floating toolbar
3. **QR from clipboard**, with local Wi-Fi share links for content too big for a QR code
4. **Keep awake**
5. **App hotkeys**, with a hotkey suggestion tool
6. **Command palette**

No new third-party dependencies. Everything below uses Apple frameworks plus the existing `KeyboardShortcuts` package.

---

## New hotkeys (defaults; all rebindable)

| Action | Default |
|---|---|
| Toggle draw-on-screen mode | `Ctrl+Opt+D` |
| Command palette | `Ctrl+Opt+Return` |
| App hotkeys (user-assigned) | `Ctrl+Opt+Cmd+<letter or digit>` |

QR and keep awake have **no global hotkeys**. They're reached from the menu bar menu and the command palette.

Updated menu bar menu:
Open History · Capture Region · Capture Window · Capture Screen · OCR · Scrolling Capture · Draw on Screen · — · Show Clipboard as QR · Keep Awake ▸ · — · Clear History · Clear All · — · Settings… · Quit
(Items for disabled modules are hidden.)

---

## 0. Groundwork: ActionRegistry + module toggles (build first)

### ActionRegistry
- One central registry of `CheeseAction` values: `id`, `title`, `symbol` (SF Symbol name), `module`, an optional `KeyboardShortcuts.Name`, `isAvailable` (false when the module is disabled or a precondition fails), and `perform(context:)`.
- The **menu bar menu, global hotkeys and the command palette all read from this registry.** Nothing defines an action in more than one place.
- `ActionContext` carries the **previously frontmost app**, captured before any Cheese UI opens, so actions launched from the palette or menu (snap window, paste) target the right app.
- Migrate all v1 actions into the registry as the first commit of v2, with no behavior change. Run the v1 manual checklist afterwards.

### Module toggles
- Settings → General → **Modules**: one switch per module: Clipboard, Screenshots, OCR, Scrolling Capture, Window Snapping, Draw on Screen, QR, Keep Awake, App Hotkeys, Command Palette. All on by default.
- A disabled module **registers no hotkeys, runs no monitors or timers, opens no listeners, and its actions disappear** from the menu and palette. Disabling Clipboard stops the pasteboard poller. Disabling QR stops any share server.
- Modules start and stop through a `CheeseModule` protocol (`start()`, `stop()`, `actions`), owned by a `ModuleManager` in `App/`. Toggling takes effect immediately, with no relaunch.

---

## 1. Draw on screen

### Entering and exiting
- `Ctrl+Opt+D` toggles draw mode. `Esc` also exits, but if a text box or sticky note is being edited, the first `Esc` only ends editing.
- On enter: a transparent overlay window covers **every display** (window level above normal and floating windows, `canJoinAllSpaces` + `fullScreenAuxiliary` so it works over full-screen apps), plus the toolbar.
- On exit: overlays and toolbar are hidden, but **drawings are kept**. Re-entering shows them again. They live in memory only: cleared by **Clear all** or when Cheese quits.

### Toolbar (Miro-style)
- A **floating vertical rail, at the left edge** of the display under the cursor, draggable anywhere. Non-activating `NSPanel`, always above the overlay.
- Sections, top to bottom:
  1. **Select** · **Pass-through (cursor)**
  2. **Pen** · **Highlighter** · **Eraser**
  3. **Rectangle** · **Ellipse** · **Line** · **Arrow**
  4. **Text** · **Sticky note**
  5. **Laser** · **Spotlight** · **Zoom**
  6. **Board** (off / whiteboard / blackboard)
  7. **Undo** · **Redo** · **Clear all** · **Snapshot**
- Choosing a tool opens a small **flyout** beside the rail with that tool's options: color swatches (9 presets + custom), stroke width (3 sizes + slider), fill on/off for shapes, font size for text, and sticky colors (Miro palette, yellow default).
- The active tool is highlighted. Hovering shows a tooltip with the tool name and its letter.

### Tools and keys (single letters, only while drawing, not in pass-through or while editing text)

| Key | Tool / action |
|---|---|
| `V` | Select: click to select, drag to move, handles to resize, `Delete` removes, `Shift`-click for multi-select |
| `M` | Pass-through: the overlay ignores the mouse, so you can click and type in apps underneath while drawings stay visible. Press `M` again or click any tool to return |
| `P` | Pen (freehand, smoothed) |
| `H` | Highlighter (semi-transparent, wide, drawn beneath pen strokes) |
| `E` | Eraser: removes whole objects it touches |
| `R` / `O` | Rectangle / ellipse (`Shift` constrains to square/circle) |
| `I` / `A` | Line / arrow (`Shift` snaps to 45° steps) |
| `T` | Text box (click to place, type, click outside to commit) |
| `N` | Sticky note (click to place a 200×200 pt note with editable text; resizable and movable with Select) |
| `L` | Laser pointer: a bright dot with a trail that fades in about 1 s. Never saved as an object |
| `S` | Spotlight: dims the screen except a circle around the cursor (scroll changes the radius) |
| `Z` | Zoom: a magnifier lens follows the cursor (scroll changes magnification) |
| `B` | Cycle board: off → whiteboard → blackboard. Boards cover the screen beneath drawings |
| `1`–`9` | Pick color preset |
| `[` / `]` | Thinner / thicker |
| `Cmd+Z` / `Cmd+Shift+Z` | Undo / redo |
| `Cmd+Shift+S` | Snapshot (same as the toolbar button) |

**Clear all** asks for confirmation if there are more than 20 objects.

### Model and rendering
- **Vector document**, not pixels: `CanvasDocument` holds per-display arrays of `CanvasItem` (`.stroke`, `.shape`, `.line`, `.arrow`, `.text`, `.sticky`) with geometry, style and z-order. The eraser, select and undo all operate on items.
- Undo/redo is a command stack (`AddItem`, `RemoveItems`, `TransformItems`, `EditText`, `ClearAll`) held in `CanvasHistory`. Keep it pure and unit-tested.
- Render with Core Graphics / `CAShapeLayer` in an `NSView` per display, not SwiftUI `Canvas`, because freehand input at 120 Hz needs low latency. Smooth strokes with Catmull-Rom splines or quadratic midpoints, in a pure `StrokeSmoother`.
- Hit-testing (`CanvasHitTester`) and smoothing are pure functions with unit tests.
- Laser, spotlight and zoom are transient layers, never items.
- **Zoom** uses ScreenCaptureKit (`SCStream`, excluding Cheese's overlay windows) to get live pixels under the cursor, so it needs Screen Recording permission. Ask only when Zoom is first chosen.

### Snapshot
- Captures the **display under the cursor including the drawings** and copies it to the clipboard, with a toast. This is the **one exception** to the v1 rule that Cheese's own windows are always excluded from captures: here the overlay must be included but the toolbar excluded.
- Holding `Shift` while clicking Snapshot opens the v1 annotation editor instead, matching v1's capture behavior.

---

## 2. QR from clipboard

- **Trigger:** menu bar item **"Show Clipboard as QR"** and the command palette. No hotkey, and no history-panel action.
- **Panel:** a floating, non-activating panel **at the center of the display under the cursor**. Large high-contrast QR code (white quiet zone, at least 320 pt), a one-line preview of the content beneath it, `Esc` or clicking outside closes it. No extra buttons beyond Close and, when sharing, **Stop sharing**.
- **Generation:** Core Image `CIQRCodeGenerator`, error correction `M`, scaled with nearest-neighbor so it stays sharp.
- **Decision rule (pure, unit-tested `QRPayloadPlanner`):**
  - Text or URL whose UTF-8 length fits in a QR code at level `M` (≈2,300 bytes) → encode directly
  - Longer text, **images, rich text, files/folders** → **local Wi-Fi share link**
  - Clipboard empty → panel says "Clipboard is empty"

### Local Wi-Fi share
- A minimal HTTP/1.1 server on **Network.framework** (`NWListener`, TCP, random free port), serving **GET only**, one resource per share.
- URL: `http://<mac-LAN-IP>:<port>/<128-bit random token>`. Requests with any other path, or after expiry, get `404`. No directory listing, no other endpoints.
- What gets served: text → a small, mobile-friendly HTML page with the text and a "Copy" button. Images → the PNG. A single file → the file with `Content-Disposition: attachment`. Multiple files or a folder → zipped on the fly to a temp file first.
- **Expiry:** 10 minutes, or when **Stop sharing** is pressed, or when the QR module is disabled, or when Cheese quits. The listener shuts down when no shares are active. Temp files are deleted on expiry.
- The panel shows the expiry countdown and "Phone must be on the same Wi-Fi".
- If there's no LAN IP (offline or no Wi-Fi), show "Not on a local network" instead of a QR code.
- ⚠️ The macOS firewall (if enabled) may prompt the first time Cheese listens. Note this in the README. Never bind to `0.0.0.0` when you can bind to the LAN interface address.

---

## 3. Keep awake

- **Menu:** `Keep Awake ▸` submenu with **Indefinitely** · **Until…** · **Turn Off** (Turn Off only when active).
- **Until…** opens a small time picker (hour and minute, 24-hour or 12-hour per system locale). A time earlier than now means tomorrow.
- Prevents **display and system idle sleep** with `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep, …)`, reason string "Cheese Keep Awake". Release on expiry, on Turn Off, when the module is disabled, and on quit.
- **Indicator:** countdown text next to the menu bar icon while active: `1h 12m`, then `42m`, and `∞` for indefinite. Update once a minute, or once a second in the final minute. Text goes away when inactive.
- Also in the command palette: "Keep Awake: Indefinitely", "Keep Awake: Until…", "Keep Awake: Turn Off".
- Not supported: keeping the Mac awake with the lid closed (needs a privileged helper). Say so in the README.
- Scheduling math (`KeepAwakeSchedule`: target date from picked time, remaining-time formatting) is pure and unit-tested.

---

## 4. App hotkeys

### Behavior
- Settings → **App Hotkeys** tab: a list of assigned apps (icon, name, hotkey recorder, remove button).
- Pressing an app's hotkey: **launch the app if it isn't running, otherwise activate it** (unhiding it if hidden). Nothing else: no hide-on-repeat, no window cycling.
- Bindings are stored by **bundle identifier**, so renamed or moved apps still work. If an app is uninstalled, show it greyed out with a "Not found" label rather than deleting the binding.
- Each binding registers through `KeyboardShortcuts` with dynamically created names (`app.<bundleID>`).

### Adding an app
- **"+"** opens a type-to-search field over installed apps: `/Applications`, `/Applications/Utilities`, `/System/Applications`, `/System/Applications/Utilities`, `~/Applications`. Fuzzy-matched with the existing `FuzzyMatcher`, showing icons. Scan in the background and cache the result. Rescan when the search opens if the cache is older than 10 minutes.
- When an app is chosen, the **suggestion tool proposes one hotkey**, with **Accept**, **Suggest another**, and the recorder for a custom key.

### Suggestion tool (`HotkeySuggester`: pure, offline, unit-tested)
- **Modifier family:** always `Ctrl+Opt+Cmd`. Keys considered: A–Z first, then 0–9.
- **Candidate order (mnemonic):**
  1. First letter of the app name (Figma → `F`)
  2. First letters of the other words (Visual Studio Code → `V`, `S`, `C`; "Microsoft" and similar vendor prefixes are skipped as the first word, so Microsoft Word → `W` first)
  3. Remaining consonants of the name, in order
  4. Remaining vowels
  5. Any other free letter, then digits
- **Filtered out:**
  - Keys already used by **any Cheese binding** (tools, palette, other apps)
  - **System shortcuts** read at runtime via `CopySymbolicHotKeys` (macOS's own keyboard shortcuts table)
  - A bundled `ReservedShortcuts.json` of known global combos from macOS and popular utilities that use `Ctrl+Opt+Cmd` (e.g. Ctrl+Opt+Cmd+8 for invert colors), easy to extend by pull request
- **"Not-so-common" scoring:** each candidate gets `mnemonicRank + conflictPenalty`, where the penalty is higher for letters commonly claimed by other apps. The lowest score wins. **Suggest another** returns the next-best candidate, cycling.
- Input: app name + set of taken shortcuts. Output: an ordered candidate list. Test with names like "Visual Studio Code", "Microsoft Word", "zoom.us", "1Password", "IINA", and with fully saturated letter sets.

---

## 5. Command palette

- `Ctrl+Opt+Return` opens a **Spotlight-style panel at the center** of the display under the cursor. Non-activating `NSPanel` with a search field focused on open.
- **Scope: Cheese actions only**, read from the `ActionRegistry`. That includes every capture/OCR/scroll action, snapping actions, Draw on Screen, Show Clipboard as QR, the Keep Awake options, Open History, Clear History, Clear All, Settings, and the Settings tabs. No app launching, no clipboard items.
- Each row: SF Symbol, title, module name in grey, and the action's current hotkey on the right if it has one, which teaches users the shortcuts.
- **Ranking:** fuzzy score (reuse `FuzzyMatcher`) plus a recency boost. With an empty query, show the 8 most recently used actions, then the rest alphabetically. Store recency in `UserDefaults`.
- `↑`/`↓` move, `Return` runs, `Esc` closes. Actions for disabled modules never appear.
- The palette closes **before** running the action and passes the previously frontmost app in `ActionContext`, so "Snap Left Half" snaps the window you were in, not the palette.

---

## Architecture additions

```
Cheese/
  App/            + ActionRegistry, CheeseAction, ActionContext, ModuleManager, CheeseModule
  Draw/           DrawModeController, OverlayWindow, CanvasView, ToolbarPanel + flyouts,
                  CanvasDocument, CanvasItem, CanvasHistory, StrokeSmoother,
                  CanvasHitTester, PresenterLayers (laser/spotlight/zoom)
  QR/             QRPanel, QRGenerator, QRPayloadPlanner, ShareServer, ShareSession
  KeepAwake/      KeepAwakeController, KeepAwakeSchedule, TimePickerView
  AppHotkeys/     AppHotkeyStore, InstalledAppIndex, HotkeySuggester,
                  SystemShortcutReader, ReservedShortcuts.json, AppHotkeysSettingsView
  Palette/        PalettePanel, PaletteViewModel, RecencyStore
```

Pure, unit-tested logic added in v2: `CanvasHistory`, `StrokeSmoother`, `CanvasHitTester`, `QRPayloadPlanner`, share token/expiry rules, `KeepAwakeSchedule`, `HotkeySuggester`, palette ranking.

## Permissions added in v2
- Draw → **Zoom** tool: Screen Recording (requested on first use of Zoom only)
- Draw → **Snapshot**: Screen Recording (already used by v1 captures)
- QR share: possible macOS firewall prompt; no TCC permission
- Keep awake, app hotkeys, palette: none

## Build order (v2)
1. ActionRegistry + ModuleManager + module toggles (refactor v1, no behavior change)
2. Keep awake
3. QR: direct encoding, then the share server
4. App hotkeys: installed-app index, bindings, then `HotkeySuggester` (tests first)
5. Command palette
6. Draw on screen, in sub-steps:
   a. overlays on all displays + toolbar shell + pass-through + enter/exit
   b. pen / highlighter / eraser + undo/redo + clear all
   c. rectangle / ellipse / line / arrow
   d. select / move / resize / delete
   e. text + sticky notes
   f. laser / spotlight / zoom
   g. boards + snapshot

End each step with the manual test checklist for the author. For draw mode, test multi-display, full-screen apps, Spaces switching, pass-through typing into another app, and drawing latency on a 120 Hz display.

## Still out of scope
Everything in v1's out-of-scope list, plus: saving drawings across quits, exporting drawings as files, QR hotkey, QR history-panel action, Wi-Fi QR maker, timer-based or app-based keep awake, closed-lid keep awake, hide-on-repeat or window cycling for app hotkeys, AI hotkey suggestions, app launching or clipboard search in the palette.
