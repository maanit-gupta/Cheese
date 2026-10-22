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
  <img alt="macOS 27+" src="https://img.shields.io/badge/macOS-27%2B-1d1d1f">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-2f9e74"></a>
</p>

<p align="center">
  <a href="https://github.com/maanit-gupta/Cheese/raw/main/docs/media/cheese-promo.mp4">
    <img src="docs/demo.gif" width="880" alt="Cheese in action: copying, capturing, drawing, converting and arranging windows from the menu bar">
  </a>
</p>

Cheese lives in your menu bar and stays out of the way until you press a shortcut. Every tool is also in its menu, any tool you don't need can be switched off, and every shortcut can be changed. The [guide](docs/GUIDE.md) covers each one in detail.

## Copy
Keep everything you copy, searchable and one keystroke from pasting. Drag any of it straight into a chat, touch up text in place before you send it, and hand any of it to your phone as a QR code.
<kbd>⌃</kbd><kbd>⌥</kbd><kbd>V</kbd> clipboard history · **Show Clipboard as QR** in the menu

## Capture
Grab a region, window or screen straight to the clipboard, copy text and QR codes from anything on screen, or let Cheese scroll a page and stitch it into one image.
<kbd>⌃</kbd><kbd>⌥</kbd><kbd>4</kbd> region · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>5</kbd> window · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>3</kbd> screen · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>T</kbd> text · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>S</kbd> scrolling · hold <kbd>⇧</kbd> to annotate

## Draw
Put smooth ink, magic shapes, stamps and a laser pointer over everything on screen, with the mouse alone.
<kbd>⌃</kbd><kbd>⌥</kbd><kbd>D</kbd> tap to toggle, hold for quick ink · hold the right button for tools

## Convert
Merge, split, compress and edit PDFs, and convert Word, Excel, PowerPoint, Markdown and images, entirely offline ([known limits](docs/GUIDE.md#convert-offline-pdf-document-and-image-tools)).
Right-click in Finder → **Cheese ▸** · drop files on the menu bar icon · **Files ▸** in the menu

## Share
Park files, images and text on a floating shelf, and send them to phones and computers nearby, through a QR code or the free LocalSend app.
<kbd>⌃</kbd><kbd>⌥</kbd><kbd>F</kbd> shelf · **Share…** in the menu or any app's Share menu

## Control
Snap windows to halves and across displays, open any app with its own shortcut, quit every open app in one go (keeping the ones you shield), keep the Mac awake, and run any Cheese action from a command palette.
<kbd>⌃</kbd><kbd>⌥</kbd> + arrows snap · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd> + a letter for your apps · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>Q</kbd> auto-kill · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>↩</kbd> palette · **Keep Awake ▸** in the menu

## Install

Requires macOS 27 or later on an Apple silicon Mac. Paste this into **Terminal**:

```sh
curl -fsSL https://raw.githubusercontent.com/maanit-gupta/Cheese/main/install.sh | bash
```

The [script](install.sh) downloads the latest release, checks its SHA-256, installs it to `/Applications` and opens Cheese.

Or download **`Cheese.zip`** from the [latest release](https://github.com/maanit-gupta/Cheese/releases/latest), unzip it and drag **Cheese.app** into **Applications**. Cheese isn't notarized by Apple, so macOS blocks the first launch:

1. Open **System Settings → Privacy & Security** and scroll to *"Cheese" was blocked…*.
2. Click **Open Anyway** and confirm. You only do this once.

When Cheese first opens, a short welcome lets you pick your tools and asks only for the permissions those need (Screen Recording, Accessibility, Notifications, Local Network, the Finder extension). A few things to know:

- The **Finder menu** has to be switched on once, in **Settings → Files → Open Extension Settings…**.
- Sharing over Wi-Fi may bring up the **macOS firewall** prompt (if your firewall is on) and a **Local Network** prompt. Allow both, or phones can't reach your Mac.
- **Keep Awake can't keep the Mac awake with the lid closed.** That needs a privileged helper, which Cheese doesn't install.

The [install guide](docs/INSTALL.md) covers updating, uninstalling and fixes for common problems.

## Privacy

Everything runs on your Mac. No accounts, no telemetry, no cloud.

Files are converted on your Mac and never uploaded. The only network use is sharing on your own local network: QR links that expire after 10 minutes, and Cheese Share, which listens only while its panel is open and for 10 minutes after. Items that password managers mark as secret are never recorded.

## Build from source

```sh
brew install xcodegen
git clone https://github.com/maanit-gupta/Cheese.git && cd Cheese
make run
```

Set `DEVELOPMENT_TEAM` in `project.yml` to your own Apple team ID first (a free personal team works). `make test` runs the unit tests and checks the app's size budget. The Xcode project is generated, so edit `project.yml` rather than `Cheese.xcodeproj`. Architecture, tests and releases are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md), design notes in [docs/DESIGN.md](docs/DESIGN.md), and the LocalSend implementation is described in [docs/LOCALSEND.md](docs/LOCALSEND.md).

Bug reports and pull requests are welcome; please open an issue first for anything big.

## License

[MIT](LICENSE) © 2026 Maanit Gupta. Global shortcuts use [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus (MIT).
