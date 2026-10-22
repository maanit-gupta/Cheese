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

        // The Share panel, live, with two files; then with nearby devices (their menus are AppKit, so
        // they render as placeholders).
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
                .padding(24)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: folder.appending(path: "\(name)-\(scheme == .light ? "light" : "dark").png"))
        }
    }
}
