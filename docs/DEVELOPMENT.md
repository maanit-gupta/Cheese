# Developing Cheese

```sh
make generate   # regenerate Cheese.xcodeproj from project.yml (XcodeGen)
make build      # Debug build
make test       # unit tests (Swift Testing), then the Release app size budget
make test-integration   # also the slower Files tests that render through WebKit
make run        # build and launch
make release    # Release build → dist/Cheese.zip + SHA-256
```

The Xcode project is generated, so edit `project.yml` rather than `Cheese.xcodeproj`. The code is organised by feature (`Clipboard/`, `Capture/`, `OCR/`, `ScrollCapture/`, `Windows/`, `Editor/`, `Draw/`, `QR/`, `KeepAwake/`, `AppHotkeys/`, `Palette/`, `Files/`, `Shelf/`, `Share/`, `Welcome/`, `Settings/`), with shared UI in `CheeseUI/` (see [DESIGN.md](DESIGN.md)), with the wiring in `App/`: every action lives once in an `ActionRegistry` that the menu, hotkeys and command palette all read, and each feature is a `CheeseModule` that can be switched off. Pure logic (fuzzy matching, stitching, sticky-header detection, snap geometry, display coordinate conversion, canvas history, stroke smoothing, the ink engine (1€ filter and variable-width outlines), shape recognition, the radial menu, hit-testing, QR payload planning, share-link rules, keep-awake scheduling, hotkey suggestions, palette ranking, and the Files tools' applicability, output naming, page ranges, split and compression planning, layout analysis, table detection and resize math) has no AppKit dependencies and is covered by unit tests.

The Finder submenu (`CheeseFinderExtension`) and the Share menu entry (`CheeseShareExtension`) are separate, sandboxed targets that only hand jobs to the app through the App Group. Cheese Share's LocalSend support is described in [LOCALSEND.md](LOCALSEND.md). The vendored JavaScript renderers live in `Cheese/Resources/Renderers/` with exact versions, licenses and the reasons for each choice in [`VENDORED.md`](../Cheese/Resources/Renderers/VENDORED.md); a test keeps them under 3 MB. The Files test fixtures are all self-made by `Design/make-files-fixtures.swift` and `.mjs`.

Known global shortcuts that the hotkey suggester should never propose live in [`ReservedShortcuts.json`](../Cheese/AppHotkeys/ReservedShortcuts.json). Add an entry there in a pull request; no code changes needed.

**Publishing a release:** bump `MARKETING_VERSION` in `project.yml`, run `make release`, then:

```sh
gh release create v0.x.y dist/Cheese.zip dist/Cheese.zip.sha256 --title "Cheese 0.x.y" --notes "…"
```

Keep the asset named `Cheese.zip`. The install script and download links point at `releases/latest/download/Cheese.zip`.

## Contributing

Bug reports and pull requests are welcome. Please open an issue first for anything big. Run `make test` before sending a PR. The build treats warnings as errors.

## App size budget

`make test` ends with `scripts/check-size.sh`, which builds Release and fails if `Cheese.app` is more than 2 MB larger than `scripts/size-baseline.txt` (the v2.5 Release bundle, in bytes). Raise the baseline only on purpose, and say why in the commit.

## Cheese Share over real HTTPS

`make test` covers Cheese Share over loopback sockets (LocalSend send/receive, messages, the phone
page) without touching the Keychain. To also run a real HTTPS round trip with a Keychain identity made
the way the app makes its own (under a throwaway label, deleted afterwards):

```sh
TEST_RUNNER_SHARE_KEYCHAIN=1 xcodebuild -project Cheese.xcodeproj -scheme Cheese -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData test -only-testing:CheeseTests/ShareHTTPSTests
```

`open cheese://share` opens the Share panel, which starts the listeners; `curl -k https://<mac-ip>:53317/api/localsend/v2/info`
then shows what LocalSend devices see.

## The phone page in Safari's engine

`PhonePageInBrowserTests` serves the real phone page and waits; `scripts/phone-page-webkit.mjs` drives it in
WebKit as an iPhone 13 (Playwright, installed for the promo render): upload a photo, send text, download
what the Mac offers. Run both together:

```sh
D=$(mktemp -d)
TEST_RUNNER_PAGE_SERVE=$D xcodebuild -project Cheese.xcodeproj -scheme Cheese -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData test -only-testing:CheeseTests/PhonePageInBrowserTests &
node scripts/phone-page-webkit.mjs $D
```
