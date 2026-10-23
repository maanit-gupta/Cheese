import AppKit
import SwiftUI
import Testing
@testable import Cheese

/// Renders the v4 panels to PNGs in `SNAPSHOT_DIR` (light and dark), to check their layout without
/// a screen and to make promo stills. Off unless that's set; see docs/DEVELOPMENT.md.
@MainActor
struct PanelSnapshotTests {
    private nonisolated static var folder: String? {
        ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]
    }

    @Test(.enabled(if: folder != nil)) func renderThePanels() async throws {
        let folder = URL(filePath: try #require(Self.folder), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = folder.appending(path: "files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let report = files.appending(path: "Q3 Report.pdf")
        let photo = files.appending(path: "Beach.heic")
        try Data(count: 1_843_000).write(to: report)
        try Data(count: 2_400_000).write(to: photo)

        // The drop hub, for a dropped PDF.
        let hub = DropHubModel(services: DropHubServices(
            canShare: { true }, canShelve: { true }, tools: { ToolApplicability.tools(for: $0) }
        ))
        hub.load(.files([report]))
        try render(StatusItemDropPanelView(model: hub), as: "drop-hub", in: folder)

        // The Share panel, live, with two files; then with nearby devices; then with a file received.
        var hooks = ShareService.Hooks(ask: { _, _ in .decline }, receivedText: { _, _ in }, setListening: { _ in })
        hooks.address = { "127.0.0.1" }
        hooks.identity = { nil }
        let service = ShareService(hooks: hooks)
        defer { service.stop() }
        let model = SharePanelModel(service: service, clipboardItems: { [] })
        model.opened()
        let deadline = Date.now.addingTimeInterval(5)
        while service.browserURL == nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        service.stage([.file(report), .file(photo)])
        try render(SharePanelView(model: model), as: "share-panel", in: folder)
        for (alias, model, type) in [("Maanit's iPhone", "iPhone", LocalSend.DeviceType.mobile), ("Studio PC", "Windows", .desktop)] {
            let info = LocalSend.DeviceInfo(alias: alias, version: "2.1", deviceModel: model, deviceType: type, fingerprint: alias, port: 53317)
            if let peer = LocalSendPeer(info: info, address: "192.168.1.\(alias.count)") {
                service.found(peer)
            }
        }
        try render(SharePanelView(model: model), as: "share-panel-devices", in: folder)
        // A photo the phone sent back, in the Received strip.
        let received = files.appending(path: "IMG_2041.HEIC")
        try Data(count: 2_400_000).write(to: received)
        service.record([received], from: "your phone")
        try render(SharePanelView(model: model), as: "share-panel-received", in: folder)

        // Show Clipboard as QR, sharing a file over a link.
        let qr = QRPanelModel()
        let link = try #require(URL(string: "http://192.168.1.42:54812/3f9a2c0011223344556677889900aabb"))
        let code = try #require(QRGenerator.image(for: link.absoluteString, minimumPixels: 360))
        qr.content = .code(image: code, side: 180, preview: "Q3 Report.pdf", share: .init(token: "t", url: link, expiresAt: .now.addingTimeInterval(598)))
        try render(QRPanelView(model: qr), as: "qr-panel", in: folder)
    }

    private func render(_ view: some View, as name: String, in folder: URL) throws {
        for scheme in [ColorScheme.light, .dark] {
            let content = view
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
                .environment(\.colorScheme, scheme)
                .environment(\.controlActiveState, .key)
                .padding(24)
            // Drawn by a hosting view in an offscreen window, so AppKit-backed controls (menus) show
            // as they do in the app rather than as ImageRenderer's placeholders.
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = KeyWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let size = host.bounds.size
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: folder.appending(path: "\(name)-\(scheme == .light ? "light" : "dark").png"))
        }
    }
}

/// Draws its controls as in the frontmost window (a blue Copy Link, not a grey one).
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
