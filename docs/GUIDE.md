# The Cheese guide

Everything Cheese does, tool by tool. The [README](../README.md) has the short version.

- [Capture](#capture) · [Copy](#copy) · [Share](#share) ([drop hub](#drop-anything-on-the-menu-bar-icon)) · [Control: windows and apps](#control-windows-and-apps) · [Draw on screen](#draw-on-screen) · [Convert](#convert-offline-pdf-document-and-image-tools) · [Control: keep awake](#control-keep-awake)
- [The menu bar menu](#the-menu-bar-menu) · [Welcome and permissions](#welcome-and-permissions) · [Keyboard shortcuts](#keyboard-shortcuts) · [Settings](#settings) · [Troubleshooting](#troubleshooting) · [Uninstall](#uninstall)

## Capture

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

## Copy

### Clipboard history
- Remembers text, rich text (pastes back with formatting), images and files.
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>V</kbd> opens the history under the menu bar icon. Start typing to fuzzy-search.
- Search also matches **text inside copied images**, which Cheese reads in the background.
- <kbd>↩</kbd> pastes into the app you were using, <kbd>⌥</kbd><kbd>↩</kbd> pastes as plain text, and <kbd>⌘</kbd><kbd>1</kbd>…<kbd>9</kbd> pastes instantly.
- Pin favourites with <kbd>⌘</kbd><kbd>P</kbd>. Pinned items never expire. Keeps your last 200 items (adjustable).
- **Drag any item out** of the history (a row, or the image or file in the preview) and drop it into Messages, Slack, Discord, a browser chat, Mail or Finder. The history fades while you're over another window so you can see where it lands, and closes after the drop. Images go as both a PNG file and image data, so web chats and native apps both take them.
- **Edit text in place**: click the ✏️ in the bottom-right corner of a text preview, or press <kbd>⌘</kbd><kbd>E</kbd>. <kbd>⌘</kbd><kbd>↩</kbd> saves and pastes, <kbd>Esc</kbd> saves and goes back to the list, and the drag handle saves and drags the edited text straight into a chat. The edit replaces the item (and the clipboard) instead of adding a copy; edited rich text becomes plain text.
- Skips anything a password manager marks as concealed or transient.

### Show clipboard as QR
- Pick **Show Clipboard as QR** from the menu or the command palette. A QR code appears in the middle of the screen, under a pill showing what's being shared.
- Short text and links go straight into the code. Anything bigger (long text, images, rich text, files, folders) is served from a **local Wi-Fi link**: the panel shows the link with **Copy Link**, a live countdown, and **Stop**. Links expire after 10 minutes. Your phone must be on the same Wi-Fi.
- Scanning the link opens the same clean page as Cheese Share (see below): the file with **Download File**, a picture with its preview, several files or a folder as **Download All (.zip)**, or long text with **Copy Text**. When the link stops, the page says so.
- The first time Cheese shares over Wi-Fi, **the macOS firewall may ask** whether Cheese can accept incoming connections (only if the firewall is on). Allow it, or the phone can't reach the link.

## Share

### Shelf
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>F</kbd> shows a floating shelf near the pointer. Drag it anywhere; it remembers the spot.
- Drop files, folders, images, text and links on it to park them while you find where they go. Or drop them on the menu bar icon and pick **Add to Shelf** in the drop hub.
- Rather not drag? Click **+** (or **Upload Files…** on an empty shelf, or press <kbd>⌘</kbd><kbd>O</kbd>) to pick files and folders, or press <kbd>⌘</kbd><kbd>V</kbd> to add what's on the clipboard.
- Files stay where they are: the shelf keeps a reference that survives renames and moves. Dropped images and text are kept in `~/Library/Application Support/Cheese/Shelf/`.
- Drag an item (or the stack handle, for everything) somewhere and it leaves the shelf. Dragging follows Finder's rules: same disk moves, another disk copies, <kbd>⌥</kbd> forces a copy. The shelf hides once it's empty.
- The toolbar has **Send…** (Cheese Share), **Files** tools for the shelf's files, **Zip** (to Downloads), **Copy Paths**, **Quick Look** (or <kbd>Space</kbd>) and **Clear**. Missing originals show greyed out.
- The shelf survives restarts. There's one shelf.

### Drop anything on the menu bar icon
- Drag files, a picture from a browser, a link or a text selection onto the 🧀. The icon lights up, and a small **drop hub** opens under it when you let go.
- At the top, a pill says what you dropped (`Report.pdf · 1.8 MB`, `4 items dropped`). Below it are two big buttons: **Share Link / QR** puts it in Cheese Share and shows the link, and **Add to Shelf** parks it on the shelf.
- For files, the **Files** tools that fit them follow, under **PDF**, **CONVERT** and **IMAGES**. Click one to open its options with the files already in.
- With Cheese Share switched off, Share Link / QR uses Show Clipboard as QR's 10-minute links instead.

### Cheese Share
- **Share…** in the menu (or the palette, the drop hub's **Share Link / QR**, the shelf's **Send…**, **Cheese Share** in any app's Share menu, or the URL `cheese://share` from Shortcuts or a script) opens the Share panel.
- **Ready to Share:** the strip at the top holds what you're sharing, like `2 items · 4.2 MB`. Drop files anywhere on the panel, click **+** to choose some, or click **Share Clipboard**. **Clear** empties it.
- **The link and QR code:** scan it with a phone, or **Copy Link** and paste it into any browser on the same Wi-Fi. No app needed. The page shows who it's connected to and what you're sharing: files with **Download File** or **Download All (.zip)**, picture previews, and text or links with **Copy Text** and **Open Link ↗**. From the same page the phone can **send photos, files and text back** with a live progress bar; received text lands on the Mac's clipboard. It follows the phone's light or dark mode, and when the link stops it says *Expired — Reopen Share on your Mac*. **Stop** ends the link at once.
- **LocalSend:** devices running the free [LocalSend](https://localsend.org) app (Android, iPhone, Windows, Linux, Mac) on the same network show up under **Nearby devices**. Click one to send what's ready, drop files straight on it, or use its **…** menu for **Send Files…** and **Send Clipboard**. A thin bar shows progress. They can send to Cheese too: you're asked first, with **Always Accept from This Device** for your own devices (manage them in **Settings → Share**).
- Received files go to **Downloads** (configurable) and a notification offers **Show in Finder**. Received text and links land on the clipboard, and in clipboard history.
- **Nothing listens until you open the Share panel.** Cheese Share stops 10 minutes after you close it; **Share** shows next to the menu bar icon meanwhile (click it to reopen the panel). Turning the Share module off stops it at once.
- LocalSend transfers are **encrypted** with a certificate Cheese makes for your Mac and keeps in the Keychain (its fingerprint is in **Settings → Share**). The browser page uses plain HTTP, because phone browsers refuse self-signed certificates, so use it on networks you trust. Its address holds a random 128-bit token, and it stops working when Share stops. Details: [LOCALSEND.md](LOCALSEND.md).
- The first time, macOS asks to let Cheese find devices on your **Local Network**. If you said no, turn Cheese on in **System Settings → Privacy & Security → Local Network**. If the macOS firewall is on, allow incoming connections for Cheese too.

## Control: windows and apps

### Window snapping
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>←</kbd> / <kbd>→</kbd> snaps to the left or right half, <kbd>↑</kbd> maximizes and <kbd>↓</kbd> snaps to the bottom half.
- Press <kbd>→</kbd> again on the right half to jump to the next display, Windows-style.
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌫</kbd> puts the window back where it was.

### Fill to Screen (Stage Manager aware)
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>M</kbd> resizes **every window of every open app** to fill its display. Windows are resized, never put into native full screen, so they stay on your desktop and Stage Manager's strip of recent apps stays visible: click any tile and its window comes up filling the screen.
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>M</kbd> does the same for just the window you're in (<kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌫</kbd> puts it back).
- **Restore All Windows** (in **Windows ▸** and the palette) puts every window back where it was before the fill, even if you filled twice.
- While Stage Manager shows its strip, windows leave room for it (196 pt on the left, or the right when the Dock is on the left). **Settings → Windows** changes the width (140–260 pt) or fills the whole screen regardless. With Stage Manager off, or its strip hidden, windows fill the whole visible screen.
- Panels, dialogs, minimized windows and windows already in full screen are left alone, and so are apps on other Spaces.

### App hotkeys
- **Settings → App Hotkeys** gives any app a <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd> + letter shortcut that opens it, or brings it to the front if it's running.
- Add an app and Cheese **suggests a free, memorable key** (Figma → <kbd>F</kbd>, Microsoft Word → <kbd>W</kbd>), skipping keys that Cheese, macOS or popular utilities already use. Accept it, ask for another, or record your own.

### Auto-Kill
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>Q</kbd> opens a list of every open app with one big **Kill All** button on top: click it or press <kbd>↩</kbd> and they all quit, as if you'd pressed <kbd>⌘</kbd><kbd>Q</kbd> in each. Apps with unsaved work still ask before quitting.
- Click the **lock** next to an app to protect it: Kill All leaves it open, today and every time after. Cheese and Finder are always left alone. **Keep [app]** leaves the app you were in open too, and **×** quits a single app.
- Hold <kbd>⌥</kbd> and the button turns red: **Force Kill All** gives apps 3 seconds to quit, then force-quits the rest. Unsaved changes in those are lost.
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>Q</kbd> sweeps straight away, without the list (shields still apply). The palette also has **Kill Background Apps (Keep Frontmost)** and **Force Kill All Open Apps**.
- **Settings → Auto-Kill** lists the protected apps, and can make every sweep force-quit apps still open after 3 seconds.

### Command palette
- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↩</kbd> opens a Spotlight-style search over every Cheese action: captures, snapping, QR, keep awake, Files tools, history and each Settings tab. (Draw mode stays out of it, and the palette doesn't open while you're drawing.)
- Each row shows the action's shortcut, so you learn them as you go. Recently used actions come first.

## Draw on screen
- **Tap** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>D</kbd> to put a transparent canvas over every display, including full-screen apps. **Hold** it for quick ink: draw while it's held, and when you let go the ink stays and your clicks go back to the apps underneath. Handy for circling something during a call.
- Ink is smooth and keeps up with fast strokes: it thins as you speed up, thickens with pressure on a Force Touch trackpad or tablet, and tapers at the ends. The cursor becomes the brush.
- **Magic pen:** draw a rough rectangle, circle, triangle, line or arrow and **hold still for a moment** before letting go. It snaps into a clean shape. Handwriting stays as you wrote it.
- **Scratch out** ink with a quick zig-zag over it.
- Everything works with the mouse alone:

| Do this | To |
|---|---|
| Hold the **right button** (or two-finger click) | Open the radial menu: magic pen, highlighter, eraser, text, stamps, sticky note, zoom and laser, with colors around the edge. Release over one, or just **flick** toward it |
| Hold <kbd>⇧</kbd> while drawing | Draw a straight line (snaps to 15°) |
| Hold <kbd>⌘</kbd> while drawing | Erase whatever you touch |
| Hold <kbd>⌥</kbd> while drawing | Highlight |
| Scroll | Change the brush size |
| <kbd>⇧</kbd> + scroll | Change the color |
| Pinch (trackpad) | Zoom lens around the cursor |
| Double-click empty space | Type text there |
| <kbd>⌘</kbd><kbd>Z</kbd> / <kbd>⌘</kbd><kbd>⇧</kbd><kbd>Z</kbd> | Undo / redo |
| <kbd>Esc</kbd> | Hide the canvas. Drawings come back next time, until you **Clear All** or quit |

- **Stamps:** ✓, ✗, ⭐, ❓ and numbered steps (①②③…, counting up with each click).
- **Disappearing ink** (toolbar): strokes fade 3 seconds after you lift the pen, which is great while presenting. **Neon** (in the pen's options) gives ink a glow.
- Presenting? **Laser pointer**, **spotlight** and **zoom** (scroll to resize or magnify), plus a whiteboard or blackboard behind your drawings.
- The tool rail on the left shrinks to a small pill while you draw; hover over it for shapes, select, pass-through, boards, undo, clear and snapshot.
- **Pass-through** lets you click and type in the apps underneath while drawings stay visible.
- **Snapshot** (<kbd>⌘</kbd><kbd>⇧</kbd><kbd>S</kbd>) copies the screen with your drawings; Shift-click it to annotate instead.
- Prefer single-letter tool keys (P, H, E, R…)? Turn on **Settings → General → Advanced: single-letter tool keys**.

## Convert: offline PDF, document and image tools
Like iLovePDF, but **entirely offline**: no file leaves your Mac and nothing touches the network. Results are saved **next to the original** (`Report.pdf` → `Report (compressed).pdf`) and nothing is ever overwritten.

Three ways in, all listing only the tools that fit your files:
- **Right-click in Finder → Cheese ▸**. Turn it on once in **Settings → Files → Open Extension Settings…** (it lists Cheese among the Finder extensions in System Settings → General → Login Items & Extensions).
- **Drop files on the menu bar icon.** The drop hub lists the matching tools under PDF, Convert and Images.
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

## Control: keep awake
- **Keep Awake ▸ Indefinitely / Until… / Turn Off** stops your Mac and display from going to sleep while idle.
- While it's on, the time left shows next to the menu bar icon (`1h 12m`, `42m`, or `∞`).
- Keeping the Mac awake **with the lid closed isn't supported**: that needs a privileged helper, which Cheese doesn't install.

## Turning tools off
Don't need a tool? Switch it off in **Settings → General → Modules** (or in the welcome screen's tool picker). A module that's off has no shortcuts, runs nothing in the background and disappears from the menu and the palette.

## The menu bar menu

Click the 🧀 in the menu bar for every tool, so shortcuts are optional:

```
 Clipboard History                ⌃⌥V
 Capture                            ▸   Region · Window · Screen · OCR · Scrolling
 Draw on Screen                   ⌃⌥D
 Files                              ▸   every Files tool
 Share…
 Shelf                            ⌃⌥F
 Windows                            ▸   Fill All to Screen ⌃⌥M · Fill Current Window ⌃⌥⇧M · Restore All Windows
                                        Left Half · Right Half · Maximize · Bottom Half · Restore Previous Size
 Tools                              ▸   Auto-Kill Apps… · Kill All Open Apps Now · Show Clipboard as QR · Keep Awake ▸
 ───────────────────────────────────
 Clear History                          (hold ⌥ for Clear All…)
 Settings…                         ⌘,
 Quit Cheese                       ⌘Q
```

Tools you've turned off disappear, and a submenu left with one item becomes a plain item. The shortcuts shown are your current ones. Keep Awake's countdown, Files progress (`3/10`) and **Share** (while Cheese Share is listening) show next to the icon, separated by `·`.

## Welcome and permissions

The first time Cheese runs it shows a short welcome: what Cheese is, a **tool picker** (switch off anything you won't use), and then **only the permissions the tools you kept need**, each with a **Grant** button and live status. Everything is skippable, and **Settings → General → Show Welcome…** brings it back.

| Permission | Needed for |
|---|---|
| **Screen Recording** | Screenshots, OCR, scrolling capture, draw-mode snapshots and zoom |
| **Accessibility** | Pasting from history, window snapping and Fill to Screen, auto-scrolling |
| **Notifications** | Finished Files jobs, files received by Cheese Share |
| **Local Network** | Cheese Share finding LocalSend devices |
| **Finder extension** | The Cheese ▸ submenu in Finder |

Files tools also ask once for **Automation → Finder**, only when you run one from the palette with Finder in front.

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
| Fill all windows to the screen | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>M</kbd> |
| Fill the current window to the screen | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>M</kbd> |
| Draw on screen (tap to toggle, hold for quick ink) | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>D</kbd> |
| Command palette | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↩</kbd> |
| Show / hide the shelf | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>F</kbd> |
| Auto-Kill: open the app list | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>Q</kbd> |
| Auto-Kill: quit all open apps now | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>Q</kbd> |
| Cheese Share | none (assign one in Settings) |
| Your app hotkeys | <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd> + a letter or digit |

Show Clipboard as QR, Keep Awake and Cheese Share have no shortcut by default; use the menu or the command palette.

### Changing shortcuts

Go to **Settings → Shortcuts** (or run "Settings: Shortcuts" from the command palette).

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
| <kbd>⌘</kbd><kbd>E</kbd> | Edit the selected text in place (again to finish) |
| <kbd>⌘</kbd><kbd>↩</kbd> | While editing: save and paste |
| <kbd>Esc</kbd> | While editing: save and go back to the list. Otherwise: close |
| Drag | Drop an item into any app |

## Settings

| Tab | What's there |
|---|---|
| **General** | Launch at login, screenshot save folder (default: Desktop), tool on/off switches, Show Welcome… |
| **Shortcuts** | Rebind every global shortcut |
| **Clipboard** | History size (default 200 unpinned items) |
| **OCR** | Languages (English, Hindi) and line-break handling |
| **Windows** | Fill to Screen: leave room for Stage Manager's strip (and how much), or fill the whole screen |
| **App Hotkeys** | Apps with their own <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd> shortcut, with key suggestions |
| **Files** | Finder extension status, and Microsoft Office / LibreOffice for Office → PDF (when installed) |
| **Share** | This Mac's name, where received files go, the largest transfer accepted (default 10 GB), trusted devices |
| **Auto-Kill** | Protected apps, and force-quitting apps still open 3 s after a sweep (off by default) |
| **Permissions** | Live status of Screen Recording and Accessibility, with shortcuts to System Settings |
| **About** | Version, license, acknowledgements and the GitHub link (also **About Cheese** in the palette) |

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

Another app may already be using it. Pick a different combination in **Settings → Shortcuts**.
</details>

<details>
<summary><b>My phone can't open the QR share link</b></summary>

The phone has to be on the same Wi-Fi as your Mac, and links stop working after 10 minutes. If the macOS firewall is on, allow incoming connections for Cheese in **System Settings → Network → Firewall → Options**. Some guest or office networks block devices from reaching each other; there's no way around that from Cheese.
</details>

<details>
<summary><b>Cheese Share doesn't find my phone or PC</b></summary>

Both have to be on the same network, the other device needs LocalSend open, and Cheese needs **Local Network** access (System Settings → Privacy & Security → Local Network). Guest and office networks often block devices from seeing each other; the **Phone** tile's QR page still works wherever the phone can reach the Mac's address.
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

The built-in renderer is approximate (see [Known limits](#convert-offline-pdf-document-and-image-tools)). If you have Microsoft Office or LibreOffice, turn on **Settings → Files → Use Microsoft Office or LibreOffice when available** for closer results.
</details>

<details>
<summary><b>I can't see the icon in the menu bar</b></summary>

On MacBooks with a notch, a crowded menu bar can hide icons. Quit a few other menu bar apps, or hold <kbd>⌘</kbd> and drag icons to rearrange them. Your shortcuts keep working even while the icon is hidden.
</details>

More fixes are in the [install guide](INSTALL.md#troubleshooting).

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
