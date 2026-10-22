import AppKit

/// Desktop office apps Files can hand Office → PDF conversions to, when the user allows it.
enum NativeOfficeApp: String, CaseIterable, Sendable {
    case word = "com.microsoft.Word"
    case excel = "com.microsoft.Excel"
    case powerPoint = "com.microsoft.Powerpoint"
    case libreOffice = "org.libreoffice.script"

    var name: String {
        switch self {
        case .word: "Microsoft Word"
        case .excel: "Microsoft Excel"
        case .powerPoint: "Microsoft PowerPoint"
        case .libreOffice: "LibreOffice"
        }
    }

    /// The Microsoft app for a kind of document.
    static func microsoft(for kind: OfficeRenderer.Kind) -> NativeOfficeApp {
        switch kind {
        case .word: .word
        case .excel: .excel
        case .powerPoint: .powerPoint
        }
    }
}

/// A native app picked for a conversion, with where it's installed.
struct NativeConverter: Sendable {
    var app: NativeOfficeApp
    var location: URL

    func convert(_ input: URL, kind: OfficeRenderer.Kind, to output: URL) async throws {
        switch app {
        case .libreOffice:
            try await LibreOfficeBridge.convert(input, soffice: location.appending(path: "Contents/MacOS/soffice"), to: output)
        case .word, .excel, .powerPoint:
            try await MicrosoftOfficeBridge.convert(input, kind: kind, to: output)
        }
    }
}

/// Finds Microsoft Office and LibreOffice with Launch Services.
@MainActor
enum NativeAppDetector {
    static func location(of app: NativeOfficeApp) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue)
    }

    static var installed: [NativeOfficeApp] {
        NativeOfficeApp.allCases.filter { location(of: $0) != nil }
    }

    static func converter(for kind: OfficeRenderer.Kind) -> NativeConverter? {
        converter(for: kind) { location(of: $0) }
    }

    /// The app to convert this kind of document with: the matching Microsoft app if it's there,
    /// else LibreOffice. Nil when neither is installed.
    nonisolated static func converter(for kind: OfficeRenderer.Kind, installed: (NativeOfficeApp) -> URL?) -> NativeConverter? {
        for app in [NativeOfficeApp.microsoft(for: kind), .libreOffice] {
            if let location = installed(app) {
                return NativeConverter(app: app, location: location)
            }
        }
        return nil
    }
}
