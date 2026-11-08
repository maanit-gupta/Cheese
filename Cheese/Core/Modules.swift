/// The feature areas the user can switch off in Settings → General → Modules.
/// A disabled module registers no hotkeys, runs nothing in the background, and its actions disappear.
enum ModuleID: String, CaseIterable, Identifiable, Sendable {
    case clipboard
    case screenshots
    case ocr
    case scrollingCapture
    case screenRecording
    case windowSnapping
    case drawOnScreen
    case qr
    /// Caffeinate. The raw value predates the name and is kept so the on/off setting carries over.
    case keepAwake
    case appHotkeys
    case commandPalette
    case files
    case shelf
    case share
    case appSweep
    case terminalTrace
    case hush
    case sweep

    var id: Self { self }

    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .screenshots: "Screenshots"
        case .ocr: "OCR"
        case .scrollingCapture: "Scrolling Capture"
        case .screenRecording: "Screen Recording"
        case .windowSnapping: "Window Snapping"
        case .drawOnScreen: "Draw on Screen"
        case .qr: "QR"
        case .keepAwake: "Caffeinate"
        case .appHotkeys: "App Hotkeys"
        case .commandPalette: "Command Palette"
        case .files: "Files"
        case .shelf: "Shelf"
        case .share: "Cheese Share"
        case .appSweep: "Auto-Kill"
        case .terminalTrace: "Terminal Trace"
        case .hush: "Hush"
        case .sweep: "Sweep"
        }
    }

    /// The verb this tool sits under in the welcome picker and the README.
    var verb: Verb {
        switch self {
        case .clipboard, .qr, .terminalTrace: .copy
        case .screenshots, .ocr, .scrollingCapture, .screenRecording: .capture
        case .drawOnScreen: .draw
        case .files: .convert
        case .share, .shelf: .share
        case .windowSnapping, .appHotkeys, .keepAwake, .commandPalette, .appSweep, .hush, .sweep: .control
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .screenshots: "camera.viewfinder"
        case .ocr: "text.viewfinder"
        case .scrollingCapture: "rectangle.expand.vertical"
        case .screenRecording: "record.circle"
        case .windowSnapping: "rectangle.split.2x1"
        case .drawOnScreen: "pencil.and.scribble"
        case .qr: "qrcode"
        case .keepAwake: "cup.and.saucer"
        case .appHotkeys: "app.badge"
        case .commandPalette: "command"
        case .files: "doc.on.doc"
        case .shelf: "tray"
        case .share: "dot.radiowaves.left.and.right"
        case .appSweep: "xmark.app"
        case .terminalTrace: "terminal"
        case .hush: "bell.slash"
        case .sweep: "bubbles.and.sparkles"
        }
    }

    /// One line on what it does, for the welcome picker.
    var blurb: String {
        switch self {
        case .clipboard: "Everything you copy, searchable and one keystroke from pasting."
        case .screenshots: "Region, window or screen, straight to the clipboard. Hold Shift to annotate."
        case .ocr: "Copy text, QR codes and barcodes from anything on screen."
        case .scrollingCapture: "Scroll a page by hand, or let it scroll itself, into one tall image."
        case .screenRecording: "Record a region or the screen, with your voice, system audio and camera, as a video or a GIF."
        case .windowSnapping: "Halves, maximize and display-to-display moves from the keyboard."
        case .drawOnScreen: "Smooth ink, magic shapes and a laser pointer over everything."
        case .qr: "Show what you copied as a QR code for your phone."
        case .keepAwake: "Keep your Mac awake for a while or until you stop, even with the lid closed."
        case .appHotkeys: "Open or switch to any app with its own shortcut."
        case .commandPalette: "Search every Cheese action from the keyboard."
        case .files: "Merge, split, compress and convert PDFs, Office files and images, offline."
        case .shelf: "A floating shelf to park files, images and text while you drag."
        case .share: "Send files and text to phones and computers nearby, LocalSend-compatible."
        case .appSweep: "Quit every open app in one go, keeping the ones you shield."
        case .terminalTrace: "Copy the terminal's last response, or everything in it, without scrolling."
        case .hush: "Keep notifications off the screen while you share it, or for as long as you like."
        case .sweep: "Lock the keyboard and trackpad for a moment while you clean the screen."
        }
    }

    /// The shortcut that best shows the tool off, if it has one.
    var mainHotkey: Hotkey? {
        switch self {
        case .clipboard: .openHistory
        case .screenshots: .captureRegion
        case .ocr: .ocrRegion
        case .scrollingCapture: .scrollingCapture
        case .screenRecording: .recordRegion
        case .windowSnapping: .snapLeft
        case .drawOnScreen: .drawOnScreen
        case .commandPalette: .commandPalette
        case .shelf: .toggleShelf
        case .appSweep: .autoKill
        case .terminalTrace: .terminalTrace
        case .qr, .keepAwake, .appHotkeys, .files, .share, .hush, .sweep: nil
        }
    }
}

/// What you do with Cheese. Cheese is described by these, never by counting its tools.
enum Verb: String, CaseIterable, Identifiable, Sendable {
    case copy
    case capture
    case draw
    case convert
    case share
    case control

    var id: Self { self }

    var title: String {
        switch self {
        case .copy: "Copy"
        case .capture: "Capture"
        case .draw: "Draw"
        case .convert: "Convert"
        case .share: "Share"
        case .control: "Control"
        }
    }

    var symbol: String {
        switch self {
        case .copy: "doc.on.clipboard"
        case .capture: "camera.viewfinder"
        case .draw: "pencil.and.scribble"
        case .convert: "arrow.triangle.2.circlepath"
        case .share: "square.and.arrow.up"
        case .control: "slider.horizontal.3"
        }
    }

    /// The tools under this verb, in `ModuleID` order.
    var modules: [ModuleID] {
        ModuleID.allCases.filter { $0.verb == self }
    }
}
