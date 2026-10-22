import AppKit

/// Show Clipboard as QR: short text goes straight into the code, anything else is served from a
/// local Wi-Fi share link. Works whether or not clipboard history is on.
@MainActor
final class QRModule: CheeseModule {
    let id = ModuleID.qr
    private let server = ShareServer()
    private lazy var panel = QRPanelController(server: server)

    var actions: [CheeseAction] {
        [
            CheeseAction(id: .showClipboardQR, title: "Show Clipboard as QR", symbol: "qrcode", module: id) { [weak self] _ in
                self?.showClipboard()
            },
        ]
    }

    // The share server only runs while a share is live.
    func start() {}

    func stop() {
        panel.close()
        server.stopAll()
    }

    private func showClipboard() {
        panel.show(Self.source(from: SystemPasteboard()))
    }

    /// The pasteboard's contents, read the same way clipboard history reads them.
    static func source(from pasteboard: some PasteboardReading) -> QRSource {
        switch ClipReader.read(from: pasteboard) {
        case nil:
            return .empty
        case let .text(plain, _, isRich):
            return isRich ? .richText(plain) : .text(plain)
        case let .image(data):
            return pngData(from: data).map { .image(png: $0) } ?? .empty
        case let .files(urls):
            return .files(urls)
        }
    }

    private static func pngData(from data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return data
        }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }
}
