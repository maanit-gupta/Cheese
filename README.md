<p align="center">
  <img src="docs/media/icon.png" width="140" alt="Cheese app icon">
</p>

<h1 align="center">Cheese</h1>

<p align="center">
  <b>The Swiss Army knife for your Mac.</b><br>
  Every little tool your Mac forgot.
</p>

<p align="center">
  <a href="https://github.com/maanit-gupta/Cheese/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/maanit-gupta/Cheese?color=FFC83D&label=download"></a>
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-1d1d1f">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-2f9e74"></a>
</p>

<p align="center">
  <a href="https://github.com/maanit-gupta/Cheese/raw/main/docs/media/cheese-promo.mp4">
    <img src="docs/demo.gif" width="880" alt="Cheese in action: searching clipboard history and batch-pasting screenshots, copying a failed test run with Terminal Trace, capturing and annotating, reading text off the screen, a scrolling capture, drawing over a slide, converting Word files from the menu bar, sharing to a phone, the Shelf, filling windows, Auto-Kill, the command palette, keeping a closed MacBook awake and a self-update">
  </a>
  <br>
  <sub>▶︎ <a href="https://github.com/maanit-gupta/Cheese/raw/main/docs/media/cheese-promo.mp4">Watch the full video</a> (MP4, 1440p, 108 s)</sub>
</p>

Cheese lives in your menu bar and stays out of the way until you press a shortcut. Every tool is also one click away in its menu, any tool you don't need can be switched off, and every shortcut can be changed. It all runs on your Mac: no account, no cloud, no telemetry.

| | |
|---|---|
| **[Copy](#copy)** | Clipboard history that searches the text inside screenshots · **batch paste** · drag to chat · edit before pasting · clipboard as QR |
| **[Terminal Trace](#terminal-trace)** | One shortcut copies your last command and everything it printed, errors pulled out, as Markdown for a chat, an issue or an AI assistant |
| **[Capture](#capture)** | Region, window and full-screen screenshots · annotation editor · copy text and QR codes from anything on screen · scrolling capture |
| **[Draw](#draw)** | Ink over any app, even full screen · magic-pen shapes · laser, spotlight and zoom · whiteboard and blackboard |
| **[Convert](#convert)** | Offline PDF merge, split, compress, watermark and page numbers · Word, Excel, PowerPoint, images and Markdown to PDF · PDF to Word, Excel and images · image convert, resize, compress and background removal |
| **[Share](#share)** | Drop anything on the menu bar icon · links and QR codes for your phone · LocalSend to phones and PCs · a floating Shelf |
| **[Control](#control)** | Window snapping · **edge-to-edge Fill to Screen** · Auto-Kill · app hotkeys · command palette |
| **[Caffeinate](#caffeinate)** | Keep your Mac awake for an hour, until a time or indefinitely, **even with the lid closed**, and let it sleep again on its own when time's up |

[New in 2.4](#new-in-24) · [New in 2.3](#new-in-23) · [Shortcuts](#keyboard-shortcuts) · [Permissions](#permissions) · [Install](#install) · [Privacy](#privacy) · [Under the hood](#under-the-hood) · [Build from source](#build-from-source)

---

## New in 2.4

- **New app icon.** A fresh cheese wedge, everywhere Cheese shows its icon.
- **Cheese updates itself.** When a release is out, a note appears and the menu shows **Update Available**; **Update & Relaunch** downloads it, checks its SHA-256 and signature, and reopens. **Check for Updates…** is in the menu, and **Settings → General → Updates** turns the automatic check off. [More](#install)
- **Draw toolbar, rebuilt.** Every button works on the first click, the toolbar stays put, and style options open only when you ask. Single-letter tool keys (<kbd>P</kbd> pen, <kbd>H</kbd> highlighter, <kbd>E</kbd> eraser…) are on by default, and the command palette opens while you draw. [More](#draw)

## New in 2.3

**Terminal Trace** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>T</kbd>
Build failed? One shortcut copies **the last command and everything it printed** from the terminal you're in, as a Markdown block ready to paste into a chat, an issue or an LLM. No scrolling, no selecting. Long output keeps the newest 120 lines, and the error lines (`error:`, `Traceback`, `npm ERR!`, `fatal:`, `panic:`…) get a block of their own. Works with Terminal, iTerm2, Ghostty, Warp, Alacritty, kitty, WezTerm and the terminals in VS Code and Cursor. [More](#terminal-trace)

**Caffeinate, even with the lid closed** (menu bar → **Caffeinate**)
Keep your Mac awake for 30 minutes, 1 or 2 hours, until a time or indefinitely, **with the lid shut**, with a countdown next to the icon (`Lid 42m`). Sleep comes back by itself: when the time runs out (a closed Mac then goes to sleep), at 10 % battery (adjustable), and if Cheese quits, crashes or the Mac restarts. Covering the lid takes your administrator password **once**, to install a small helper. [More](#caffeinate)

**Batch paste** in clipboard history
Hold <kbd>⇧</kbd> with <kbd>↑</kbd> <kbd>↓</kbd> (or <kbd>⇧</kbd>-click, <kbd>⌘</kbd>-click, <kbd>⌘</kbd><kbd>A</kbd>) to pick several items, then <kbd>↩</kbd> pastes them all with **a single <kbd>⌘</kbd><kbd>V</kbd>**, in the order you picked them. Three screenshots land in Slack, Notes, Finder or a chat box at once; snippets are joined with blank lines. <kbd>⌥</kbd><kbd>↩</kbd> pastes one by one for apps that take one image per paste. [More](#copy)

**Fill to Screen, truly edge to edge** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>M</kbd>
**Fill All to Screen** and **Fill Current Window** (<kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>M</kbd>) now cover the whole display with **Stage Manager** on. Stage Manager used to push filled windows back out to the right, leaving a gap down the left where its strip sits; Cheese now puts each window back after resizing it, so nothing is left uncovered and the strip reappears at the screen edge when you need it. Prefer to keep the strip in view? **Settings → Windows** can still leave room for it. [More](#control)

---

## Copy

Keep everything you copy, find it in a keystroke, and get it where it needs to go.

**Clipboard history** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>V</kbd>
- Remembers text, rich text (it pastes back with its formatting), images and files, and survives restarts.
- Opens under the menu bar icon with the search field ready: type to fuzzy-search, including **the words inside copied screenshots**, which Cheese reads in the background.
- <kbd>↩</kbd> pastes into the app you were in, <kbd>⌥</kbd><kbd>↩</kbd> pastes plain text, <kbd>⌘</kbd><kbd>1</kbd>…<kbd>9</kbd> pastes instantly. <kbd>⌘</kbd><kbd>P</kbd> pins favourites so they never expire.
- Skips anything a password manager marks as secret.

**Paste several at once**
- Hold <kbd>⇧</kbd> with <kbd>↑</kbd> <kbd>↓</kbd> (or <kbd>⇧</kbd>-click) to select a run of items, <kbd>⌘</kbd>-click to pick them one by one, or <kbd>⌘</kbd><kbd>A</kbd> for everything that matches your search.
- <kbd>↩</kbd> pastes them all with a single <kbd>⌘</kbd><kbd>V</kbd>, in the order you picked them: text is joined with blank lines, and screenshots and files go in together, so a whole batch of screenshots lands in Slack, Finder, Notes or a chat box at once.
- <kbd>⌥</kbd><kbd>↩</kbd> pastes them **one by one** for apps that only take one image per paste, and <kbd>⌘</kbd><kbd>C</kbd> just copies the batch.

**Drag to chat, edit in place**
- **Drag any item straight out of the history** (a row, or the image or file in the preview) into Messages, Slack, Discord, WhatsApp, a browser chat, Mail or Finder. The history fades while you aim, then closes after the drop. Images travel as both a file and image data, so web chats and native apps both accept them.
- **Fix text before you send it:** click the small ✏️ in the bottom-right corner of a text preview (or press <kbd>⌘</kbd><kbd>E</kbd>), edit in place, then <kbd>⌘</kbd><kbd>↩</kbd> to paste or grab the drag handle to drop the edited text into a chat. The edit replaces the item rather than adding a copy.

**Show Clipboard as QR** (menu bar → **Tools**, or the palette)
- Short text and links go straight into a QR code for your phone's camera.
- Anything bigger (long text, images, files, folders) becomes a **10-minute local Wi-Fi link** with **Copy Link**, a live countdown and **Stop**. Scanning it opens the same clean page as [Cheese Share](#share).

## Terminal Trace

Build failed? Don't scroll up and drag-select it: press <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>T</kbd>.

- Copies **the last command and everything it printed** from your terminal, ready to paste into a chat or an issue as a Markdown code block. Long output keeps the newest 120 lines, and error lines (`error:`, `Traceback`, `npm ERR!`, `fatal:`, `panic:`…) get their own block.
- Works with Terminal, iTerm2, Ghostty, Warp, Alacritty, kitty, WezTerm, and the terminals in VS Code and Cursor.
- **Tools ▸ Terminal Trace** switches between **Last Response** and **Everything** (the whole scrollback, uncut); the shortcut copies with whichever you picked last.

## Capture

Screenshots go straight to the clipboard at full Retina resolution, or into a folder, or both: pick under **Capture ▸ After Capture** or in **Settings → General**.

| Shortcut | Does |
|---|---|
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>4</kbd> | Drag a region on any display |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>5</kbd> | Click a window, shadow and all |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>3</kbd> | The display under the pointer |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>T</kbd> | **Copy text** from any region: videos, images, locked PDFs, slides. English and Hindi. QR codes and barcodes too, and links get an *Open* button |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>S</kbd> | **Scrolling capture:** pick an area and Cheese scrolls and stitches one tall image, keeping sticky headers once. It's copied or saved like any capture, and a preview lets you copy, save, annotate or read its text |

**Hold <kbd>⇧</kbd> as you finish** any capture to open the annotation editor instead: arrows, boxes, text, highlighter, blur, crop and undo, then **Copy** or **Save** as PNG.

## Draw

Draw on top of everything on screen, including full-screen apps, with the mouse or trackpad alone.

- **Tap** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>D</kbd> for a canvas over every display. **Hold** it for quick ink: draw while it's held, and when you let go your clicks pass back to the apps underneath. Perfect for circling something on a call.
- Ink keeps up with fast strokes: it thins with speed, thickens with pressure and tapers at the ends.
- **Magic pen:** draw a rough rectangle, circle, triangle, line or arrow, pause for a moment, and it snaps into a clean shape. Handwriting stays handwriting. **Scratch out** ink with a quick zig-zag.
- **Hold the right button** for a radial menu (magic pen, highlighter, eraser, text, stamps, sticky notes, zoom and laser, with colors around the edge), or just **flick** toward a tool.
- Hold <kbd>⇧</kbd> for straight lines, <kbd>⌘</kbd> to erase, <kbd>⌥</kbd> to highlight. Scroll for size, <kbd>⇧</kbd> + scroll for color, pinch to zoom, double-click to type.
- Presenting? Laser pointer, spotlight, zoom lens, disappearing ink, neon pen, numbered stamps, and a whiteboard or blackboard. **Snapshot** (<kbd>⌘</kbd><kbd>⇧</kbd><kbd>S</kbd>) copies the screen with your drawings.

## Convert

Like iLovePDF, but **entirely offline**. No file leaves your Mac. Results are saved next to the original (`Report.pdf` → `Report (compressed).pdf`), and nothing is ever overwritten.

| | Tools |
|---|---|
| **PDF** | Merge (keeps bookmarks) · Split by ranges, every N pages or each page · Page editor (reorder, rotate, delete, extract) · **Compress to a target size** · Watermark · Page numbers |
| **To PDF** | Images (HEIC included) · Word · Excel / CSV · PowerPoint · HTML, Markdown and text |
| **From PDF** | Images (72–300 DPI) · Word (.docx) · Excel (.xlsx) |
| **Images** | Convert format · Resize · Compress (strips location data) · Remove background |
| **Text** | Markdown or HTML → Word |

Three ways in, each listing only the tools that fit your files: **right-click in Finder → Cheese ▸**, **drop files on the menu bar icon**, or type "Files:" in the command palette. A small panel shows your files and options, progress shows next to the icon, and a notification offers **Show in Finder** when it's done. Office rendering is built in and approximate; see the [known limits](docs/GUIDE.md#convert-offline-pdf-document-and-image-tools).

## Share

Get things from your Mac to a phone, a PC or another Mac nearby, and back, with no account and no cloud.

**Drop anything on the menu bar icon**

Drag files, a picture from a browser, a link or a text selection onto the 🧀. It lights up, and a small drop hub opens right under it:

<p align="center"><img src="docs/media/share-mac.png" width="760" alt="The drop hub under the menu bar icon (Share Link / QR, Add to Shelf, and the PDF tools for a dropped report) next to the Cheese Share panel with its Ready to Share strip, a photo just received from a phone, the QR code with Copy Link, and nearby devices"></p>

- **Share Link / QR** puts it in Cheese Share and shows its link and QR code at once.
- **Add to Shelf** parks it on the [Shelf](#share).
- Below them come the **Files** tools that fit (PDF, Convert, Images), with your files already in.

**Cheese Share** (menu bar → **Share…**, the palette, the Shelf's **Send…**, or any app's Share menu)
- **Ready to Share:** drop files anywhere on the panel, click **+**, or click **Share Clipboard**.
- **One link for everything:** scan the QR code with a phone, or **Copy Link** and open it in any browser on the same Wi-Fi. No app needed.
- **What comes back lands in the panel:** files sent from a phone or another device appear in a green **Received** strip. **Show** reveals them in Finder, and **⋯** opens any one of them. The list stays after sharing stops, until you clear it.
- **LocalSend built in:** phones and computers running the free [LocalSend](https://localsend.org) app (Android, iPhone, Windows, Linux, Mac) appear under **Nearby devices**. Click one to send what's ready, or drop files straight onto it. They can send to you too, after you accept (or always, for your own devices). Transfers are encrypted.

**The page your phone opens** is clean and light, follows the phone's light or dark mode, and works over plain local Wi-Fi:

<p align="center"><img src="docs/media/share-phone.png" width="560" alt="Cheese Share's phone page in light and dark mode: connected to the Mac, a file with Download File, shared text with Copy Text and Open Link, and an uploader that shows Sent to Mac"></p>

- **From your Mac:** files with **Download File** (or **Download All (.zip)**), picture previews, and text or links with **Copy Text** and **Open Link ↗**.
- **Send to your Mac:** tap to pick photos or files (or drag them in on a desktop) and watch them upload with a live progress bar, no page reloads. Paste text or a link and tap **Send** to put it on the Mac's clipboard and in its history.
- The page shows the time left and switches to *Expired — Reopen Share on your Mac* when the link stops.

**Shelf** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>F</kbd>
- A floating shelf to park files, folders, images, text and links while you find where they go. Drop things on it, or click **+** / **Upload Files…**, or press <kbd>⌘</kbd><kbd>V</kbd>.
- Drag items (or the whole stack) out, and they leave the shelf, following Finder's move or copy rules. **Send…**, **Zip**, **Copy Paths**, **Quick Look** and the Files tools are in its toolbar. The shelf survives restarts.

## Control

Windows, apps and your Mac, on your terms.

- **Snap windows** <kbd>⌃</kbd><kbd>⌥</kbd> + <kbd>←</kbd> <kbd>→</kbd> <kbd>↑</kbd> <kbd>↓</kbd>: halves, maximize and bottom half, Windows-style. Press again to hop to the next display. <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌫</kbd> puts the window back.
- **Fill to Screen** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>M</kbd>: resizes **every open window** to fill its display **edge to edge**, without entering native full screen, so it works with **Stage Manager**: no gap down the side where the strip of recent apps sits, and any tile you click comes up properly maximized. The menu bar and the Dock (wherever it is right now, hidden or not) are respected. <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>M</kbd> does just the current window; **Restore All Windows** undoes it. Prefer to keep the strip in view? **Settings → Windows** can leave room for it.
- **Auto-Kill** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>Q</kbd>: one big **Kill All** button for every open app, with a 🔒 shield for the ones that should stay. Hold <kbd>⌥</kbd> to force-kill. <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>Q</kbd> sweeps without asking. Cheese and Finder are always spared.
- **App hotkeys** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd> + a letter: give any app its own shortcut to open or bring it forward. Cheese suggests a free, memorable key.
- **Command palette** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↩</kbd>: search and run any Cheese action. It shows each one's shortcut, so you learn them as you go.

## Caffeinate

Rendering, downloading or presenting on a closed MacBook? Menu bar → **Caffeinate** (or the command palette).

- Keep your Mac awake for **30 minutes, 1 or 2 hours, until a time or indefinitely**, with a countdown next to the icon (`Lid 42m`). Pick another length while it's on to change it; **Turn Off** ends it early.
- **Even with the lid closed**, on battery too. **Keep Awake With Lid Closed** is on by default; untick it and closing the lid sleeps the Mac as usual.
- **Sleep comes back on its own:** when the time runs out (a closed Mac then goes to sleep), at 10 % battery (adjustable in **Settings → Caffeinate**), and even if Cheese quits or crashes, or the Mac restarts.
- Covering the lid takes your administrator password **once**, to install a small helper. [Why](#install)

---

## Keyboard shortcuts

Every shortcut can be changed or turned off in **Settings → Shortcuts**, and the menu bar menu always shows your current ones.

| Action | Default |
|---|---|
| Clipboard history | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>V</kbd> |
| Capture region · window · full screen | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>4</kbd> · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>5</kbd> · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>3</kbd> (hold <kbd>⇧</kbd> to annotate) |
| Copy text from screen (OCR) | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>T</kbd> |
| Terminal Trace | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>T</kbd> |
| Scrolling capture | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>S</kbd> |
| Draw on screen (tap to toggle, hold for quick ink) | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>D</kbd> |
| Shelf | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>F</kbd> |
| Snap left / right half | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>←</kbd> / <kbd>→</kbd> |
| Maximize · bottom half | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↑</kbd> · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↓</kbd> |
| Restore window | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌫</kbd> |
| Fill all windows · fill current window | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>M</kbd> · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>M</kbd> |
| Auto-Kill panel · kill all now | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>Q</kbd> · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>Q</kbd> |
| Command palette | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↩</kbd> |
| Your app hotkeys | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd> + a letter or digit |
| Cheese Share | none by default (assign one in Settings) |

Inside the clipboard history: type to search · <kbd>↑</kbd> <kbd>↓</kbd> to move · <kbd>⇧</kbd><kbd>↑</kbd> <kbd>⇧</kbd><kbd>↓</kbd>, <kbd>⇧</kbd>-click or <kbd>⌘</kbd>-click to select several · <kbd>⌘</kbd><kbd>A</kbd> select all · <kbd>↩</kbd> paste (several: all at once, <kbd>⌥</kbd><kbd>↩</kbd> one by one, <kbd>⌘</kbd><kbd>C</kbd> copy) · <kbd>⌥</kbd><kbd>↩</kbd> plain text · <kbd>⌘</kbd><kbd>1</kbd>…<kbd>9</kbd> quick paste · <kbd>⌘</kbd><kbd>P</kbd> pin · <kbd>⌘</kbd><kbd>⌫</kbd> delete · <kbd>⌘</kbd><kbd>E</kbd> edit text · drag to drop into any app · <kbd>Esc</kbd> close.

While drawing: right button for tools · <kbd>⇧</kbd> line · <kbd>⌘</kbd> erase · <kbd>⌥</kbd> highlight · scroll for size · <kbd>⌘</kbd><kbd>Z</kbd> undo · <kbd>Esc</kbd> hide. The [guide](docs/GUIDE.md#keyboard-shortcuts) has the rest.

## Permissions

On first launch, a short welcome lets you pick your tools and then asks **only for the permissions those need**, each with a **Grant** button and live status. Everything is skippable, and **Settings → Permissions** shows the same status later.

| Permission | Needed for |
|---|---|
| **Screen Recording** | Screenshots, OCR, scrolling capture, and draw mode's snapshot and zoom |
| **Accessibility** | Pasting from history, window snapping, Fill to Screen, auto-scrolling, Terminal Trace in terminals other than Terminal and iTerm2 |
| **Notifications** | Finished Files jobs, files received through Cheese Share |
| **Local Network** | Cheese Share finding nearby LocalSend devices |
| **Finder extension** | The **Cheese ▸** menu in Finder (turn it on in **Settings → Files**) |
| **Automation** (asked on first use) | **Finder**, so a Files tool run from the palette can read Finder's selection · **Terminal** or **iTerm2**, so Terminal Trace can read the front tab · Word, Excel or PowerPoint, only if you turn on the Office fallback in **Settings → Files** |
| **Administrator password** (once) | Installing Caffeinate's lid-closed helper, the first time a session covers a closed lid |

## Install

Requires **macOS 15 Sequoia** or later on an Apple silicon Mac. Paste this into **Terminal**:

```sh
curl -fsSL https://raw.githubusercontent.com/maanit-gupta/Cheese/main/install.sh | bash
```

The [script](install.sh) downloads the latest release, checks its SHA-256, installs it to `/Applications` and opens Cheese.

After that, **Cheese updates itself**: when a new release is out, a note appears and the menu shows **Update Available**. Pick **Update & Relaunch** and Cheese downloads it, checks its SHA-256 and code signature, swaps itself out in place and reopens. **Check for Updates…** is in the menu too.

Or download **`Cheese.zip`** from the [latest release](https://github.com/maanit-gupta/Cheese/releases/latest), unzip it and drag **Cheese.app** into **Applications**. Cheese isn't notarized by Apple, so macOS blocks the first launch:

1. Open **System Settings → Privacy & Security** and scroll to *"Cheese" was blocked…*.
2. Click **Open Anyway** and confirm. You only do this once.

Good to know:
- Sharing over Wi-Fi may show the **macOS firewall** prompt (if your firewall is on) and a **Local Network** prompt. Allow both, or phones can't reach your Mac.
- **Caffeinate asks for your administrator password once.** Keeping a Mac awake with the lid closed needs `pmset -a disablesleep 1`, so the first such session installs a small root helper (a shell script run by launchd; macOS lists it under Login Items as a background item). It only turns lid-close sleep off while Cheese asks, and turns it back on when the session ends, Cheese quits or crashes, or the Mac restarts. Remove it in **Settings → Caffeinate**.

The [install guide](docs/INSTALL.md) covers updating, uninstalling and fixes for common problems, and the [guide](docs/GUIDE.md) covers every tool in detail.

## Privacy

Everything runs on your Mac. No accounts, no telemetry, no cloud.

- Files are converted on your Mac and never uploaded. The Office renderers are bundled and blocked from loading anything remote.
- Sharing stays on **your own local network**, and nothing listens unless you ask. Show Clipboard as QR links expire after 10 minutes. Cheese Share listens only while its panel is open and for 10 minutes after, with a fresh random link each time.
- The one request to the internet is the **update check**: at launch and every 12 hours Cheese asks GitHub's public API for the latest release, sending nothing about you or your Mac. Turn it off in **Settings → General → Updates**.
- The phone page is entirely self-contained: no outside scripts, fonts or trackers.
- Items that password managers mark as secret are never recorded.

## Under the hood

- A native menu bar app in **Swift 6** (strict concurrency) for **macOS 15+ on Apple silicon**, built on Apple frameworks: ScreenCaptureKit, Vision, PDFKit, WebKit, Network and the Accessibility API. The only package is [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).
- **Every tool is a module** you can switch off in **Settings → General**. A tool that's off costs nothing: no shortcuts, timers, listeners or menu entries.
- **Every action is defined once** and shared by the menu, the shortcuts and the command palette, so they never disagree.
- The Finder menu and the Share menu entry are small sandboxed extensions that only hand work to the app.
- Updates need no framework: a small built-in updater reads GitHub's latest release, checks the download's SHA-256 and that it's signed by the same team, and swaps the app in place with a script that keeps the old copy until the new one is in.
- The one privileged piece is Caffeinate's lid-closed helper: a short shell script run by launchd that turns lid-close sleep off only while Cheese asks for it, and back on when the session ends or Cheese is gone. Its every line is covered by tests that run it against stand-ins for `pmset`.
- The logic behind each tool (stitching, snapping, ink smoothing, shape recognition, Terminal Trace parsing, batch paste ordering, PDF planning…) is plain Swift with no UI, covered by several hundred unit tests.

More in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Build from source

```sh
brew install xcodegen
git clone https://github.com/maanit-gupta/Cheese.git && cd Cheese
make run
```

Set `DEVELOPMENT_TEAM` in `project.yml` to your own Apple team ID first (a free personal team works). The Xcode project is generated, so edit `project.yml` rather than `Cheese.xcodeproj`.

| Command | Does |
|---|---|
| `make build` | Debug build (must finish with zero warnings) |
| `make test` | Unit tests, then the app size budget check |
| `make run` | Build and open the app |
| `make release` | Release build, zipped to `dist/Cheese.zip` with its `.sha256` |

Architecture, tests, the phone page in WebKit and releases are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md); design notes and tokens are in [docs/DESIGN.md](docs/DESIGN.md); the LocalSend implementation is in [docs/LOCALSEND.md](docs/LOCALSEND.md); the promo video is rebuilt from `Design/promo` ([how](docs/DEVELOPMENT.md#promo-video)).

Bug reports and pull requests are welcome; please open an issue first for anything big.

## License

[MIT](LICENSE) © 2026 Maanit Gupta. Global shortcuts use [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus (MIT).
