import os

extension Logger {
    private static let subsystem = "com.maanitgupta.cheese"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let core = Logger(subsystem: subsystem, category: "Core")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
    static let clipboard = Logger(subsystem: subsystem, category: "Clipboard")
    static let capture = Logger(subsystem: subsystem, category: "Capture")
    static let editor = Logger(subsystem: subsystem, category: "Editor")
    static let ocr = Logger(subsystem: subsystem, category: "OCR")
    static let scrollCapture = Logger(subsystem: subsystem, category: "ScrollCapture")
    static let windows = Logger(subsystem: subsystem, category: "Windows")
    static let welcome = Logger(subsystem: subsystem, category: "Welcome")
    static let keepAwake = Logger(subsystem: subsystem, category: "KeepAwake")
    static let qr = Logger(subsystem: subsystem, category: "QR")
    static let appHotkeys = Logger(subsystem: subsystem, category: "AppHotkeys")
    static let palette = Logger(subsystem: subsystem, category: "Palette")
    static let draw = Logger(subsystem: subsystem, category: "Draw")
    static let files = Logger(subsystem: subsystem, category: "Files")
    static let shelf = Logger(subsystem: subsystem, category: "Shelf")
    static let share = Logger(subsystem: subsystem, category: "Share")
    static let appSweep = Logger(subsystem: subsystem, category: "AppSweep")
}
