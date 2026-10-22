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
}
