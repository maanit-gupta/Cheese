import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// What the QR panel shows.
@MainActor
@Observable
final class QRPanelModel {
    struct Share: Equatable {
        var token: String
        var expiresAt: Date
    }

    enum Content {
        case message(title: String, detail: String?, symbol: String)
        case preparing
        case code(image: CGImage, scale: CGFloat, preview: String, share: Share?)
    }

    var content = Content.preparing
    var onClose: () -> Void = {}
    var onStopSharing: (String) -> Void = { _ in }

    var share: Share? {
        if case let .code(_, _, _, share) = content { return share }
        return nil
    }
}

/// Shows the clipboard as a QR code: directly when it fits, otherwise as a local Wi-Fi share link.
@MainActor
final class QRPanelController {
    /// The QR code is never drawn smaller than this, in points.
    static let minimumCodeSize: CGFloat = 320

    private let server: ShareServer
    private let model = QRPanelModel()
    private lazy var panel = makePanel()
    private var showTask: Task<Void, Never>?

    init(server: ShareServer) {
        self.server = server
        model.onClose = { [weak self] in self?.close() }
        model.onStopSharing = { [weak self] token in
            self?.server.stop(token)
            self?.close()
        }
        server.onShareEnded = { [weak self] token in self?.shareEnded(token) }
    }

    func show(_ source: QRSource) {
        showTask?.cancel()
        model.content = .preparing
        panel.present()
        showTask = Task { [weak self] in await self?.prepare(source) }
    }

    func close() {
        showTask?.cancel()
        showTask = nil
        panel.dismiss()
    }

    private func prepare(_ source: QRSource) async {
        let plan = QRPayloadPlanner.plan(for: source) { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        switch plan {
        case .empty:
            show(.message(title: "Clipboard is empty", detail: "Copy some text, an image or files first.", symbol: "clipboard"))
        case let .direct(text):
            if let code = makeCode(for: text) {
                show(.code(image: code.image, scale: code.scale, preview: Self.preview(of: text), share: nil))
            } else {
                await share(.text(text), preview: Self.preview(of: text))
            }
        case let .share(content):
            await share(content, preview: Self.preview(of: content))
        }
    }

    private func share(_ content: ShareContent, preview: String) async {
        guard let address = LANAddress.current() else {
            show(.message(title: "Not on a local network", detail: "Connect to Wi-Fi to share this with a phone.", symbol: "wifi.slash"))
            return
        }
        do {
            let resource = try await Self.resource(for: content)
            guard !Task.isCancelled else {
                for file in resource.temporaryFiles { try? FileManager.default.removeItem(at: file) }
                return
            }
            let (session, url) = try await server.share(resource, on: address)
            guard let code = makeCode(for: url.absoluteString) else {
                server.stop(session.token)
                return
            }
            show(.code(
                image: code.image, scale: code.scale, preview: preview,
                share: QRPanelModel.Share(token: session.token, expiresAt: session.expiresAt)
            ))
        } catch {
            Logger.qr.error("Sharing failed: \(error.localizedDescription, privacy: .public)")
            show(.message(title: "Couldn't share this", detail: error.localizedDescription, symbol: "exclamationmark.triangle"))
        }
    }

    private func show(_ content: QRPanelModel.Content) {
        guard !Task.isCancelled else { return }
        model.content = content
    }

    private func shareEnded(_ token: String) {
        guard model.share?.token == token else { return }
        show(.message(title: "Link expired", detail: "Show the clipboard as QR again for a new link.", symbol: "clock.badge.xmark"))
    }

    private func makeCode(for message: String) -> (image: CGImage, scale: CGFloat)? {
        let scale = Screens.underMouse?.backingScaleFactor ?? 2
        guard let image = QRGenerator.image(for: message, minimumPixels: Int(Self.minimumCodeSize * scale)) else { return nil }
        return (image, scale)
    }

    private func makePanel() -> CheesePanel {
        let panel = CheesePanel(rootView: QRPanelView(model: model))
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    // MARK: Content

    @concurrent
    private static func resource(for content: ShareContent) async throws -> ShareResource {
        switch content {
        case let .text(text):
            return ShareResource(contentType: "text/html; charset=utf-8", body: .data(Data(SharePage.html(for: text).utf8)))
        case let .image(png):
            return ShareResource(contentType: "image/png", body: .data(png))
        case let .file(url):
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return ShareResource(contentType: type, body: .file(url), attachmentName: url.lastPathComponent)
        case let .archive(urls):
            let archive = try await ShareArchiver.archive(urls)
            return ShareResource(
                contentType: "application/zip", body: .file(archive.zip),
                attachmentName: archive.zip.lastPathComponent, temporaryFiles: [archive.temporaryFolder]
            )
        }
    }

    static func preview(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { $0.contains { !$0.isWhitespace } } ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    static func preview(of content: ShareContent) -> String {
        switch content {
        case let .text(text):
            return preview(of: text)
        case let .image(png):
            return "Image · " + ByteCountFormatter.string(fromByteCount: Int64(png.count), countStyle: .file)
        case let .file(url):
            return url.lastPathComponent
        case let .archive(urls):
            return urls.count == 1 ? (urls.first?.lastPathComponent ?? "Folder") : "\(urls.count) items"
        }
    }
}

private struct QRPanelView: View {
    let model: QRPanelModel

    var body: some View {
        VStack(spacing: 14) {
            switch model.content {
            case .preparing:
                ProgressView()
                    .controlSize(.large)
                    .frame(width: QRPanelController.minimumCodeSize, height: QRPanelController.minimumCodeSize)
            case let .message(title, detail, symbol):
                CheeseEmptyState(symbol: symbol, title: title, detail: detail)
                    .frame(width: QRPanelController.minimumCodeSize)
            case let .code(image, scale, preview, share):
                Image(decorative: image, scale: scale)
                    .interpolation(.none)
                    // White quiet zone, whatever the appearance.
                    .padding(DesignTokens.Spacing.xLarge)
                    .background(.white, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
                Text(preview)
                    .font(DesignTokens.Typography.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: CGFloat(image.width) / scale)
                if let share {
                    ShareStatus(expiresAt: share.expiresAt)
                }
            }
            HStack {
                if let share = model.share {
                    Button("Stop Sharing") { model.onStopSharing(share.token) }
                }
                Spacer()
                Button("Close") { model.onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DesignTokens.Spacing.xxLarge)
        .fixedSize()
        .cheesePanelBackground()
    }
}

private struct ShareStatus: View {
    let expiresAt: Date

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xxSmall) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded(.up)))
                Text("Link expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                    .monospacedDigit()
            }
            Label("Phone must be on the same Wi-Fi", systemImage: "wifi")
                .foregroundStyle(.secondary)
        }
        .font(DesignTokens.Typography.caption)
    }
}
