import os

extension Logger {
    private static let subsystem = "com.maanitgupta.cheese"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let core = Logger(subsystem: subsystem, category: "Core")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
}
