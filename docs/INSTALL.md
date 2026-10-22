# Installing Cheese

This guide takes you from download to a working Cheese in about two minutes. Pick **one** of the three install options, then follow [First launch](#first-launch).

- [Requirements](#requirements)
- [Option 1: one-line install](#option-1-one-line-install-recommended)
- [Option 2: download the zip](#option-2-download-the-zip)
- [Option 3: build from source](#option-3-build-from-source)
- [First launch](#first-launch)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)

## Requirements

- **macOS 27** or later (check with  → About This Mac)
- An **Apple silicon** Mac (M1 or newer)
- About 10 MB of disk space

Cheese ships as a **zip file**, not a `.dmg`. There's nothing to mount or eject.

## Option 1: one-line install (recommended)

1. Open **Terminal** (press <kbd>⌘</kbd><kbd>Space</kbd>, type *Terminal*, press <kbd>↩</kbd>).
2. Paste this line and press <kbd>↩</kbd>:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/maanit-gupta/Cheese/main/install.sh | bash
   ```

3. If `/Applications` isn't writable by your account, you'll be asked for your Mac password.

The [install script](../install.sh) does exactly five things:

1. downloads `Cheese.zip` from the [latest GitHub release](https://github.com/maanit-gupta/Cheese/releases/latest)
2. checks it against the published SHA-256 checksum
3. quits Cheese if it's running and replaces `/Applications/Cheese.app`
4. removes the quarantine flag, so Gatekeeper doesn't block an app that isn't notarized
5. opens Cheese

**Without admin rights?** Install into your user Applications folder instead:

```sh
curl -fsSL https://raw.githubusercontent.com/maanit-gupta/Cheese/main/install.sh | CHEESE_INSTALL_DIR=~/Applications bash
```

Continue with [First launch](#first-launch).

## Option 2: download the zip

1. Go to the [latest release](https://github.com/maanit-gupta/Cheese/releases/latest) and download **`Cheese.zip`** under *Assets*.
2. Open your **Downloads** folder and double-click `Cheese.zip`. Finder unzips it to **Cheese.app**.
3. Drag **Cheese.app** into your **Applications** folder.
4. Double-click **Cheese** in Applications.

### Getting past Gatekeeper (one time only)

Cheese is free and open source, and it isn't notarized by Apple (that needs a paid developer account). The first time you open it, macOS shows **"Cheese" Not Opened** or **Apple could not verify "Cheese"…**. That's expected.

1. Click **Done** (not *Move to Trash*).
2. Open ** → System Settings → Privacy & Security**.
3. Scroll down to **Security**. You'll see *"Cheese" was blocked to protect your Mac.*
4. Click **Open Anyway**, then confirm with your password or Touch ID.
5. In the dialog that follows, click **Open Anyway** again.

macOS remembers this choice, so you won't see the warning again for this copy of Cheese.

**Or use Terminal** instead of steps 1–5:

```sh
xattr -dr com.apple.quarantine /Applications/Cheese.app
open /Applications/Cheese.app
```

### Optional: verify the download

Each release also includes `Cheese.zip.sha256`. Download both files into the same folder, then:

```sh
cd ~/Downloads && shasum -a 256 -c Cheese.zip.sha256
```

You should see `Cheese.zip: OK`.

## Option 3: build from source

You need **Xcode 27** and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/maanit-gupta/Cheese.git
cd Cheese
```

Open `project.yml` and set `DEVELOPMENT_TEAM` to **your** Apple team ID. A free personal team from any Apple ID works: in Xcode, open *Settings → Accounts* and add your Apple ID. Then:

```sh
make run        # Debug build, launched from build/DerivedData
make release    # or: Release build, zipped into dist/Cheese.zip
```

Sign with a stable identity rather than ad hoc. macOS ties Screen Recording and Accessibility grants to the signature, so a changing signature means granting permissions again after every build.

## First launch

### 1. The welcome guide

The first time Cheese opens, a short welcome guide appears:

| Page | What it's for |
|---|---|
| **Welcome** | The five tools and their shortcuts |
| **Permissions** | Live status of the two permissions, with buttons that open the right System Settings page |
| **Shortcuts** | Rebind any shortcut on the spot |
| **All set** | Turn on *Open Cheese automatically when you log in* |

You can close it at any time and reopen it later from the menu bar icon → **Welcome Guide…**

### 2. Grant permissions

Cheese asks for these only because the features can't work without them. Nothing leaves your Mac.

**Screen Recording**, used for screenshots, OCR and scrolling capture:

1. In the welcome guide (or **Settings → Permissions**), click **Open System Settings** next to Screen Recording.
2. Turn on **Cheese** in the list.
3. If macOS offers **Quit & Reopen**, click it. Otherwise click the menu bar icon → **Quit Cheese**, then open Cheese again.

**Accessibility**, used for pasting from history, window snapping and auto-scrolling:

1. Click **Open System Settings** next to Accessibility.
2. Turn on **Cheese**. No restart is needed.

The welcome guide and Settings show a green ✓ as soon as each permission is granted.

You can skip both for now. When you use a feature that needs a missing permission, Cheese explains why and links to the right page.

### 3. Find Cheese in the menu bar

Look for the cheese wedge near the clock.

**Click** it to open the Cheese menu. Every feature is there, so you never *have* to remember a shortcut:

| Menu item | What it does |
|---|---|
| **Clipboard History** | Opens your history under the icon |
| **Capture:** Region, Window, Full Screen, Scrolling Capture | Takes a screenshot (hold <kbd>⇧</kbd> as you finish to annotate) |
| **Text:** Copy Text from Screen | OCR: drag over anything to copy its text |
| **Windows:** Arrange Window ▸ | Left half, right half, maximize, bottom half, restore, for the window you were using |
| **Clear History / Clear All…** | Empties history (Clear All also removes pins) |
| **Keyboard Shortcuts…** | Change any shortcut |
| **Settings… / Welcome Guide… / Quit Cheese** | |

Each item shows its current shortcut on the right.

### 4. Make the shortcuts yours (optional)

Click the menu bar icon → **Keyboard Shortcuts…**. Click any shortcut, press the new keys, and it takes effect immediately. Click **ⓧ** to turn a shortcut off, or **Restore Defaults** to start over.

## Updating

Run the [one-line install](#option-1-one-line-install-recommended) again, or download the new `Cheese.zip` and replace the app in Applications. Your history, pins, settings and shortcuts are kept.

Permissions usually carry over because every release is signed with the same certificate. If a feature stops working after an update, see [Permissions are on but features still don't work](#permissions-are-on-but-features-still-dont-work).

## Uninstalling

1. Click the menu bar icon → **Quit Cheese**.
2. Delete the app and its data:

   ```sh
   rm -rf /Applications/Cheese.app "$HOME/Library/Application Support/Cheese"
   defaults delete com.maanitgupta.cheese
   ```

3. Optionally, remove the permission entries:

   ```sh
   tccutil reset ScreenCapture com.maanitgupta.cheese
   tccutil reset Accessibility com.maanitgupta.cheese
   ```

4. If you turned on launch at login, remove Cheese from **System Settings → General → Login Items**.

`~/Library/Application Support/Cheese` holds your clipboard history (`History.store`) and copied images (`Images/`). Screenshots you saved yourself stay where you put them.

## Troubleshooting

### "Cheese is damaged and can't be opened"
This is Gatekeeper's quarantine flag on a download that isn't notarized, not real damage. Run:

```sh
xattr -dr com.apple.quarantine /Applications/Cheese.app
```

### "Cheese needs macOS 27 or later" from the install script
Cheese uses APIs that only exist in macOS 27. Update macOS in **System Settings → General → Software Update**.

### Screenshots show only the wallpaper, or nothing happens
Screen Recording isn't active yet. Turn it on (see [Grant permissions](#2-grant-permissions)), then **quit and reopen** Cheese. macOS only applies a new Screen Recording grant after a relaunch.

### Choosing an item in history copies it but doesn't paste
Pasting into other apps needs **Accessibility**. Without it, Cheese copies the item so you can press <kbd>⌘</kbd><kbd>V</kbd> yourself.

### Permissions are on but features still don't work
macOS can keep a stale entry after an app is replaced. For each permission:

1. Open **System Settings → Privacy & Security → Screen Recording** (or **Accessibility**).
2. Select **Cheese** and click **–** to remove it.
3. Click **+**, choose **Applications → Cheese**, and turn it on.
4. Quit and reopen Cheese.

### A shortcut does nothing
Another app or a macOS shortcut may already use that combination. Click the menu bar icon → **Keyboard Shortcuts…** and choose a different one. Cheese warns you if macOS has already reserved a combination.

### Window snapping doesn't move a window
Check Accessibility first. Some windows, like fixed-size panels and certain dialogs, can't be resized. Cheese moves them as far as they allow.

### Scrolling capture stops early or repeats content
Pages that change while scrolling (auto-playing carousels, lazy-loaded feeds) can confuse stitching. Select only the part of the page that scrolls, and avoid areas with animations.

### Hindi isn't available for OCR
Cheese checks which languages the system's text recognizer supports. If Hindi shows as unavailable in **Settings → OCR**, your macOS installation doesn't offer it yet. English still works.

### The icon is missing from the menu bar
On Macs with a notch, extra icons can hide behind it. Quit a few other menu bar apps, or hold <kbd>⌘</kbd> and drag icons to rearrange them. Shortcuts work even while the icon is hidden. To check that Cheese is running, look for it in **Activity Monitor**.

### Still stuck?
[Open an issue](https://github.com/maanit-gupta/Cheese/issues/new). Include your macOS version, what you expected and what happened.
