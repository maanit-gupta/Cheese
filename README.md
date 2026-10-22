<p align="center">
  <img src="docs/media/icon.png" width="140" alt="Cheese app icon">
</p>

<h1 align="center">Cheese</h1>

<p align="center">
  <b>Eleven everyday Mac tools in one tiny menu bar app.</b><br>
  Capture &amp; OCR · Clipboard · Windows &amp; apps · Draw on screen · Files · Keep awake<br>
  <sub>Native · offline · every shortcut rebindable · MIT licensed</sub>
</p>

<p align="center">
  <a href="https://github.com/maanit-gupta/Cheese/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/maanit-gupta/Cheese?color=FFC83D&label=download"></a>
  <img alt="macOS 27+" src="https://img.shields.io/badge/macOS-27%2B-1d1d1f">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-native-1d1d1f">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-2f9e74"></a>
</p>

<p align="center">
  <a href="https://github.com/maanit-gupta/Cheese/releases/latest"><b>Download</b></a> ·
  <a href="#at-a-glance"><b>Features</b></a> ·
  <a href="docs/INSTALL.md"><b>Install guide</b></a> ·
  <a href="#keyboard-shortcuts"><b>Shortcuts</b></a> ·
  <a href="#troubleshooting"><b>Troubleshooting</b></a>
</p>

<p align="center">
  <a href="https://github.com/maanit-gupta/Cheese/raw/main/docs/media/cheese-promo.mp4">
    <img src="docs/media/cheese-promo.gif" width="880" alt="Cheese promo: clipboard history, screenshots, OCR, scrolling capture, window snapping, draw on screen, the command palette, PDF and file tools, QR codes and app hotkeys">
  </a>
  <br>
  <sub>▶︎ <a href="https://github.com/maanit-gupta/Cheese/raw/main/docs/media/cheese-promo.mp4">Watch the full-quality video (MP4)</a></sub>
</p>

---

Cheese replaces a drawer full of single-purpose utilities (a clipboard manager, a screenshot tool, a text grabber, a window manager, a screen annotator, a keep-awake toggle, an app launcher and an online PDF converter) with one native app. It lives in your menu bar, starts instantly and stays out of the way until you press a shortcut.

- **Native.** Swift 6, SwiftUI and AppKit, built on ScreenCaptureKit, Vision, PDFKit and Accessibility. No Electron. The Files tools render Office documents with small bundled JavaScript libraries in a hidden web view that can't reach the network.
- **Private.** Everything stays on your Mac. No accounts, analytics or internet access. The only network use is the optional local Wi-Fi share link for QR codes, which serves one file to your own network for 10 minutes. Files are converted on your Mac and never uploaded. Items that password managers mark as secret are never recorded or shown.
- **Yours to tweak.** Every shortcut can be changed, any tool you don't need can be switched off, and the source is MIT licensed.

## At a glance

| | Tool | What it does | Default shortcut |
|---|---|---|---|
| **📸&nbsp;Capture** | [Screenshots](#screenshots) | Region, window or full screen, straight to the clipboard. Hold <kbd>⇧</kbd> to annotate | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>4</kbd> · <kbd>5</kbd> · <kbd>3</kbd> |
| | [Scrolling capture](#scrolling-capture) | Scrolls the page for you and stitches one tall image | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>S</kbd> |
| | [Copy text (OCR)](#copy-text-from-anything-ocr) | Text, QR codes and barcodes from any part of the screen | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>T</kbd> |
| **📋&nbsp;Clipboard** | [Clipboard history](#clipboard-history) | Searchable history of text, images and files, one keystroke from pasting | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>V</kbd> |
| | [Clipboard as QR](#show-clipboard-as-qr) | Send what you copied to your phone with a QR code | Menu · palette |
| **🪟&nbsp;Windows&nbsp;&amp;&nbsp;apps** | [Window snapping](#window-snapping) | Halves, maximize, restore and multi-display moves | <kbd>⌃</kbd><kbd>⌥</kbd> + arrows |
| | [App hotkeys](#app-hotkeys) | Open or switch to any app with its own shortcut | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd> + key |
| | [Command palette](#command-palette) | Search and run every Cheese action | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↩</kbd> |
| **🎨&nbsp;Present** | [Draw on screen](#-draw-on-screen) | Pens, shapes, sticky notes, laser, spotlight and zoom over everything | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>D</kbd> |
| **📄&nbsp;Files** | [PDF, document and image tools](#-files-offline-pdf-document-and-image-tools) | Merge, split, compress, convert and edit, fully offline | Finder · drop on icon · palette |
| **☕&nbsp;Utilities** | [Keep awake](#keep-awake) | Stop your Mac sleeping, indefinitely or until a set time | Menu · palette |

Every tool is also in the menu bar menu, so shortcuts are optional.

## 📸 Capture and text

### Screenshots
- **Region** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>4</kbd>, **full screen** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>3</kbd> and **window** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>5</kbd> (with its shadow).
- Copied straight to the clipboard at full Retina resolution. Nothing clutters your desktop.
- **Hold <kbd>⇧</kbd> as you finish** to open the annotation editor: arrows, boxes, text, highlighter, blur, crop, and undo/redo. Save as PNG or copy.

### Scrolling capture
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>S</kbd>, then select the scrollable area. Cheese scrolls for you and stitches one tall image.
- Sticky headers and footers are detected and kept once, not repeated.
- Stops by itself at the end of the page, or when you press <kbd>Esc</kbd>. Then copy, save, annotate or OCR the result.

### Copy text from anything (OCR)
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>T</kbd>, then drag over any part of the screen: videos, images, locked PDFs or slides.
- Recognises **English and Hindi**. You choose whether to keep line breaks or join them into paragraphs.
- **QR codes and barcodes** are read too. Links get an *Open* button.

## 📋 Clipboard

### Clipboard history
- Remembers text, rich text (pastes back with formatting), images and files.
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>V</kbd> opens the history under the menu bar icon. Start typing to fuzzy-search.
- Search also matches **text inside copied images**, which Cheese reads in the background.
- <kbd>↩</kbd> pastes into the app you were using, <kbd>⌥</kbd><kbd>↩</kbd> pastes as plain text, and <kbd>⌘</kbd><kbd>1</kbd>…<kbd>9</kbd> pastes instantly.
- Pin favourites with <kbd>⌘</kbd><kbd>P</kbd>. Pinned items never expire. Keeps your last 200 items (adjustable).
- Skips anything a password manager marks as concealed or transient.

### Show clipboard as QR
- Pick **Show Clipboard as QR** from the menu or the command palette. A large QR code appears in the middle of the screen.
- Short text and links go straight into the code. Anything bigger (long text, images, rich text, files, folders) is served from a **local Wi-Fi link** that expires after 10 minutes or when you press **Stop Sharing**. Your phone must be on the same Wi-Fi.
- The first time Cheese shares over Wi-Fi, **the macOS firewall may ask** whether Cheese can accept incoming connections (only if the firewall is on). Allow it, or the phone can't reach the link.

## 🪟 Windows and apps

### Window snapping
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>←</kbd> / <kbd>→</kbd> snaps to the left or right half, <kbd>↑</kbd> maximizes and <kbd>↓</kbd> snaps to the bottom half.
- Press <kbd>→</kbd> again on the right half to jump to the next display, Windows-style.
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌫</kbd> puts the window back where it was.

### App hotkeys
- **Settings → App Hotkeys** gives any app a <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd> + letter shortcut that opens it, or brings it to the front if it's running.
- Add an app and Cheese **suggests a free, memorable key** (Figma → <kbd>F</kbd>, Microsoft Word → <kbd>W</kbd>), skipping keys that Cheese, macOS or popular utilities already use. Accept it, ask for another, or record your own.

### Command palette
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↩</kbd> opens a Spotlight-style search over every Cheese action: captures, snapping, draw mode, QR, keep awake, Files tools, history and each Settings tab.
- Each row shows the action's shortcut, so you learn them as you go. Recently used actions come first.

## 🎨 Draw on screen
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>D</kbd> puts a transparent canvas over every display, including full-screen apps, with a Miro-style tool rail on the left (drag it anywhere).
- Pen, highlighter, eraser, rectangle, ellipse, line, arrow, text and sticky notes. Hold <kbd>⇧</kbd> for squares, circles and 45° lines.
- Presenting? **Laser pointer**, **spotlight** and **zoom** (scroll to resize or magnify), plus a whiteboard or blackboard behind your drawings.
- **Pass-through** (<kbd>M</kbd>) lets you click and type in the apps underneath while drawings stay visible.
- **Snapshot** (<kbd>⌘</kbd><kbd>⇧</kbd><kbd>S</kbd>) copies the screen with your drawings; Shift-click it to annotate instead.
- <kbd>Esc</kbd> hides the canvas. Drawings come back next time, until you **Clear All** or quit.

| Key | Tool | Key | Tool |
|---|---|---|---|
| <kbd>V</kbd> | Select, move, resize | <kbd>T</kbd> | Text |
| <kbd>M</kbd> | Pass-through | <kbd>N</kbd> | Sticky note |
| <kbd>P</kbd> | Pen | <kbd>L</kbd> | Laser pointer |
| <kbd>H</kbd> | Highlighter | <kbd>S</kbd> | Spotlight |
| <kbd>E</kbd> | Eraser | <kbd>Z</kbd> | Zoom |
| <kbd>R</kbd> / <kbd>O</kbd> | Rectangle / ellipse | <kbd>B</kbd> | Board: off → white → black |
| <kbd>I</kbd> / <kbd>A</kbd> | Line / arrow | <kbd>1</kbd>–<kbd>9</kbd> | Color preset |
| <kbd>[</kbd> / <kbd>]</kbd> | Thinner / thicker | <kbd>⌘</kbd><kbd>Z</kbd> / <kbd>⌘</kbd><kbd>⇧</kbd><kbd>Z</kbd> | Undo / redo |

## 📄 Files: offline PDF, document and image tools
Like iLovePDF, but **entirely offline**: no file leaves your Mac and nothing touches the network. Results are saved **next to the original** (`Report.pdf` → `Report (compressed).pdf`) and nothing is ever overwritten.

Three ways in, all listing only the tools that fit your files:
- **Right-click in Finder → Cheese ▸**. Turn it on once in **Settings → Files → Open Extension Settings…** (it lists Cheese among the Finder extensions in System Settings → General → Login Items & Extensions).
- **Drop files on the menu bar icon.** A menu pops up with the matching tools, grouped under PDF, Convert and Images.
- **The command palette:** type "Files:". If Finder is in front, Cheese uses its selection (macOS asks once to let Cheese read it); otherwise it asks you to choose files.

Pick a tool and a small panel shows the files (drag to reorder where order matters), the options, and **Run**. Options are remembered per tool. While jobs run, progress shows next to the icon (`3/10`) and the menu gets a **Cancel** item; a notification with **Show in Finder** arrives when they're done.

| | Tools |
|---|---|
| **PDF** | Merge (keeps bookmarks) · Split by ranges (`1-3, 5, 8-`), every N pages or each page · **Page editor** to reorder, rotate, delete and extract pages · **Compress to a target size** · Watermark (text or image) · Page numbers |
| **To PDF** | Images (fit, A4 or Letter; HEIC included) · Word · Excel / CSV · PowerPoint · HTML, Markdown and text |
| **From PDF** | Images (PNG or JPEG at 72/150/300 DPI) · Word (.docx) · Excel (.xlsx) |
| **Images** | Convert format (PNG, JPEG, HEIC, TIFF, GIF, BMP, and WebP where macOS can write it) · Resize · Compress (strips location data by default) · Remove background |
| **Text** | Markdown or HTML → Word |

Watermarks and page numbers keep your PDF's text selectable. Compression only re-renders image-heavy pages; text pages stay sharp.

**Known limits.** Office rendering is built in and approximate:
- **Word:** page breaks may land differently from Word on long documents; complex floating layouts, SmartArt and charts can be simplified.
- **Excel:** values only, as plain tables, with no cell colors, fonts or charts. Each sheet starts on a new page.
- **PowerPoint:** the roughest of the three. Animations, some shapes, SmartArt and embedded media aren't rendered.
- **PDF → Word / Excel:** layout is approximate, multi-column pages may need cleanup, complex or merged-cell tables won't be perfect, and text inside images isn't converted unless the whole page is a scan (scans are read with on-device OCR).

If **Microsoft Office or LibreOffice** is installed, **Settings → Files** offers to use it for Office → PDF instead (off by default). macOS asks once per app to let Cheese control it, and the app may open while it works. If it fails, Cheese falls back to its built-in renderer and says so.

## ☕ Utilities

### Keep awake
- **Keep Awake ▸ Indefinitely / Until… / Turn Off** stops your Mac and display from going to sleep while idle.
- While it's on, the time left shows next to the menu bar icon (`1h 12m`, `42m`, or `∞`).
- Keeping the Mac awake **with the lid closed isn't supported**: that needs a privileged helper, which Cheese doesn't install.

## 🧩 Modules
Don't need a tool? Switch it off in **Settings → General → Modules**. A module that's off has no shortcuts, runs nothing in the background and disappears from the menu and the palette.

## Install

> **Requirements:** macOS 27 or later on an Apple silicon Mac.

### Option 1: one-line install (recommended)

Paste this into **Terminal**:

```sh
curl -fsSL https://raw.githubusercontent.com/maanit-gupta/Cheese/main/install.sh | bash
```

The [script](install.sh) downloads the latest release, verifies its checksum, installs it to `/Applications`, clears the Gatekeeper quarantine flag and opens Cheese. It's short; read it first if you like.

### Option 2: download the zip

1. Download **`Cheese.zip`** from the [latest release](https://github.com/maanit-gupta/Cheese/releases/latest). It's a plain zip, not a disk image.
2. Double-click it to unzip, then drag **Cheese.app** into **Applications**.
3. Open Cheese. macOS will block the first launch because Cheese isn't notarized by Apple:
   - Go to **System Settings → Privacy & Security** and scroll down to *"Cheese" was blocked…*.
   - Click **Open Anyway** and confirm with your password or Touch ID.

   You only do this once. Prefer Terminal? `xattr -dr com.apple.quarantine /Applications/Cheese.app` does the same.

### Option 3: build from source

```sh
brew install xcodegen
git clone https://github.com/maanit-gupta/Cheese.git && cd Cheese
make run
```

Set `DEVELOPMENT_TEAM` in `project.yml` to your own Apple team ID first. A free personal team works.

📖 **The [full install guide](docs/INSTALL.md)** covers each step in detail, plus updating, uninstalling and fixes for common problems.

## First launch

Cheese opens a short **welcome guide** the first time it runs:

1. **What Cheese does**, with the shortcut for each tool.
2. **Permissions.** Cheese needs two, and both are granted in System Settings → Privacy & Security:

   | Permission | Needed for |
   |---|---|
   | **Screen Recording** | Screenshots, OCR, scrolling capture, draw-mode snapshots and zoom |
   | **Accessibility** | Pasting from history, window snapping, auto-scrolling |

   You can skip this step. Cheese asks the first time a feature needs a permission.
3. **Shortcuts.** Rebind anything you like right there.
4. **Launch at login**, if you want it.

After that, look for the 🧀 wedge in your menu bar. **Click it to open the Cheese menu.** Every feature is there, so shortcuts are optional:

```
 Clipboard History                ⌃⌥V
 ───────────────────────────────────
 CAPTURE
 Capture Region                   ⌃⌥4
 Capture Window                   ⌃⌥5
 Capture Full Screen              ⌃⌥3
 Scrolling Capture                ⌃⌥S
 TEXT
 Copy Text from Screen            ⌃⌥T
 WINDOWS
 Arrange Window                     ▸
 UTILITIES
 Draw on Screen                   ⌃⌥D
 Show Clipboard as QR
 Keep Awake                         ▸
 ───────────────────────────────────
 Clear History
 Clear All…
 ───────────────────────────────────
 Command Palette                  ⌃⌥↩
 Keyboard Shortcuts…
 Settings…                         ⌘,
 Welcome Guide…
 Quit Cheese                       ⌘Q
```

The shortcuts shown are your current ones, and they update when you change them. **Welcome Guide…** reopens the guide. While Files jobs run, a **Files: Merging 3 PDFs… — Cancel** line appears at the top.

Files tools also ask for two optional permissions when first used: **Notifications** (to tell you a job finished) and **Automation → Finder** (only when you run a Files tool from the palette with Finder in front).

## Keyboard shortcuts

| Action | Default |
|---|---|
| Open clipboard history | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>V</kbd> |
| Capture region | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>4</kbd> |
| Capture full screen | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>3</kbd> |
| Capture window | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>5</kbd> |
| Copy text from region (OCR) | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>T</kbd> |
| Scrolling capture | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>S</kbd> |
| Snap left / right half | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>←</kbd> / <kbd>→</kbd> |
| Maximize | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↑</kbd> |
| Snap bottom half | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↓</kbd> |
| Restore window | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌫</kbd> |
| Toggle draw on screen | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>D</kbd> |
| Command palette | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↩</kbd> |
| Your app hotkeys | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd> + a letter or digit |

Show Clipboard as QR and Keep Awake have no shortcut; use the menu or the command palette.

### Changing shortcuts

Click the menu bar icon and choose **Keyboard Shortcuts…** (or go to **Settings → Shortcuts**).

- **Click** a shortcut, then **press the new keys**.
- Click **ⓧ** to turn a shortcut off.
- **Restore Defaults** puts everything back.

Cheese warns you if a combination is already taken by macOS or the menu. The menu bar menu always shows your current bindings.

### Inside the clipboard history

| Key | Action |
|---|---|
| Type | Filter (fuzzy search) |
| <kbd>↑</kbd> / <kbd>↓</kbd> | Move selection |
| <kbd>↩</kbd> | Paste into the previous app |
| <kbd>⌥</kbd><kbd>↩</kbd> | Paste as plain text |
| <kbd>⌘</kbd><kbd>1</kbd> … <kbd>⌘</kbd><kbd>9</kbd> | Paste the Nth item |
| <kbd>⌘</kbd><kbd>P</kbd> | Pin / unpin |
| <kbd>⌘</kbd><kbd>⌫</kbd> | Delete item |
| <kbd>Esc</kbd> | Close |

## Settings

| Tab | What's there |
|---|---|
| **General** | Launch at login, screenshot save folder (default: Desktop), module on/off switches, welcome guide |
| **Shortcuts** | Rebind every global shortcut |
| **Clipboard** | History size (default 200 unpinned items) |
| **OCR** | Languages (English, Hindi) and line-break handling |
| **App Hotkeys** | Apps with their own <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd> shortcut, with key suggestions |
| **Files** | Finder extension status, and Microsoft Office / LibreOffice for Office → PDF (when installed) |
| **Permissions** | Live status of Screen Recording and Accessibility, with shortcuts to System Settings |
| **About** | Version, license, and the licenses of the bundled document renderers |

## Troubleshooting

<details>
<summary><b>"Cheese can't be opened" or "Apple could not verify…"</b></summary>

Cheese isn't notarized. Open **System Settings → Privacy & Security** and click **Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Cheese.app
```
</details>

<details>
<summary><b>Screenshots only show the wallpaper, or capture does nothing</b></summary>

Turn on **Cheese** under **System Settings → Privacy & Security → Screen Recording**, then quit Cheese (menu bar icon → Quit Cheese) and open it again.
</details>

<details>
<summary><b>Choosing an item in history copies it but doesn't paste</b></summary>

Pasting needs **Accessibility** access. Turn on Cheese under **Privacy & Security → Accessibility**. If it's already on but still doesn't work (for example after an update), select Cheese in that list, remove it with **–**, and add it again.
</details>

<details>
<summary><b>A shortcut doesn't do anything</b></summary>

Another app may already be using it. Pick **Keyboard Shortcuts…** from the menu bar icon and choose a different combination.
</details>

<details>
<summary><b>My phone can't open the QR share link</b></summary>

The phone has to be on the same Wi-Fi as your Mac, and links stop working after 10 minutes. If the macOS firewall is on, allow incoming connections for Cheese in **System Settings → Network → Firewall → Options**. Some guest or office networks block devices from reaching each other; there's no way around that from Cheese.
</details>

<details>
<summary><b>Keep Awake doesn't work with the lid closed</b></summary>

That's expected. Keeping a Mac awake with the lid closed needs a privileged helper, which Cheese doesn't install. With the lid open (or an external display, keyboard and power connected), Keep Awake works as usual.
</details>

<details>
<summary><b>There's no "Cheese ▸" when I right-click files in Finder</b></summary>

The Finder extension has to be switched on once: **Settings → Files → Open Extension Settings…**, then turn on **Cheese**. If it's on but missing, relaunch Finder (hold <kbd>⌥</kbd>, right-click Finder in the Dock → Relaunch). The submenu only appears when at least one tool fits the selection, and shows "Cheese Files is turned off" if the Files module is off.
</details>

<details>
<summary><b>A converted Word, Excel or PowerPoint file doesn't look like the original</b></summary>

The built-in renderer is approximate (see [Known limits](#-files-offline-pdf-document-and-image-tools)). If you have Microsoft Office or LibreOffice, turn on **Settings → Files → Use Microsoft Office or LibreOffice when available** for closer results.
</details>

<details>
<summary><b>I can't see the icon in the menu bar</b></summary>

On MacBooks with a notch, a crowded menu bar can hide icons. Quit a few other menu bar apps, or hold <kbd>⌘</kbd> and drag icons to rearrange them. Your shortcuts keep working even while the icon is hidden.
</details>

More fixes are in the [install guide](docs/INSTALL.md#troubleshooting).

## Uninstall

Quit Cheese, then:

```sh
rm -rf /Applications/Cheese.app "$HOME/Library/Application Support/Cheese"
defaults delete com.maanitgupta.cheese
tccutil reset ScreenCapture com.maanitgupta.cheese
tccutil reset Accessibility com.maanitgupta.cheese
tccutil reset AppleEvents com.maanitgupta.cheese
rm -rf "$HOME/Library/Group Containers/8H5274FWRC.com.maanitgupta.cheese"
```

If you turned on launch at login, also remove Cheese from **System Settings → General → Login Items**.

## Development

```sh
make generate   # regenerate Cheese.xcodeproj from project.yml (XcodeGen)
make build      # Debug build
make test       # unit tests (Swift Testing)
make test-integration   # also the slower Files tests that render through WebKit
make run        # build and launch
make release    # Release build → dist/Cheese.zip + SHA-256
```

The Xcode project is generated, so edit `project.yml` rather than `Cheese.xcodeproj`. The code is organised by feature (`Clipboard/`, `Capture/`, `OCR/`, `ScrollCapture/`, `Windows/`, `Editor/`, `Draw/`, `QR/`, `KeepAwake/`, `AppHotkeys/`, `Palette/`, `Files/`, `Welcome/`, `Settings/`), with the wiring in `App/`: every action lives once in an `ActionRegistry` that the menu, hotkeys and command palette all read, and each feature is a `CheeseModule` that can be switched off. Pure logic (fuzzy matching, stitching, sticky-header detection, snap geometry, display coordinate conversion, canvas history, stroke smoothing, hit-testing, QR payload planning, share-link rules, keep-awake scheduling, hotkey suggestions, palette ranking, and the Files tools' applicability, output naming, page ranges, split and compression planning, layout analysis, table detection and resize math) has no AppKit dependencies and is covered by unit tests. [`CLAUDE.md`](CLAUDE.md), [`CLAUDE-V2.md`](CLAUDE-V2.md) and [`CLAUDE-V2.5.md`](CLAUDE-V2.5.md) have the full spec and architecture notes.

The Finder submenu is a separate, sandboxed `CheeseFinderExtension` target that only builds the menu and hands jobs to the app through the App Group. The vendored JavaScript renderers live in `Cheese/Resources/Renderers/` with exact versions, licenses and the reasons for each choice in [`VENDORED.md`](Cheese/Resources/Renderers/VENDORED.md); a test keeps them under 3 MB. The Files test fixtures are all self-made by `Design/make-files-fixtures.swift` and `.mjs`.

Known global shortcuts that the hotkey suggester should never propose live in [`ReservedShortcuts.json`](Cheese/AppHotkeys/ReservedShortcuts.json). Add an entry there in a pull request; no code changes needed.

**Publishing a release:** bump `MARKETING_VERSION` in `project.yml`, run `make release`, then:

```sh
gh release create v0.x.y dist/Cheese.zip dist/Cheese.zip.sha256 --title "Cheese 0.x.y" --notes "…"
```

Keep the asset named `Cheese.zip`. The install script and download links point at `releases/latest/download/Cheese.zip`.

## Contributing

Bug reports and pull requests are welcome. Please open an issue first for anything big. Run `make test` before sending a PR. The build treats warnings as errors.

## License

[MIT](LICENSE) © 2026 Maanit Gupta. Global shortcuts use [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus (MIT).
