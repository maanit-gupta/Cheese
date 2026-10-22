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
        var url: URL
        var expiresAt: Date
    }

    enum Content {
        case message(title: String, detail: String?, symbol: String)
        case preparing
        /// `side` is the code's size in points.
        case code(image: CGImage, side: CGFloat, preview: String, share: Share?)
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
    /// A share link's code, in points: links are short, so their codes are coarse and scan easily.
    nonisolated static let linkCodeSide: CGFloat = 180

    /// Text in the code itself makes a denser code, drawn bigger so a phone can still read it.
    nonisolated static func codeSide(forDirectBytes bytes: Int) -> CGFloat {
        switch bytes {
        case ...150: linkCodeSide
        case ...800: 240
        default: 320
        }
    }

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
            let side = Self.codeSide(forDirectBytes: text.utf8.count)
            if let code = makeCode(for: text, side: side) {
                show(.code(image: code, side: side, preview: Self.preview(of: text), share: nil))
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
            guard let code = makeCode(for: url.absoluteString, side: Self.linkCodeSide) else {
                server.stop(session.token)
                return
            }
            show(.code(
                image: code, side: Self.linkCodeSide, preview: preview,
                share: QRPanelModel.Share(token: session.token, url: url, expiresAt: session.expiresAt)
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

    private func makeCode(for message: String, side: CGFloat) -> CGImage? {
        let scale = Screens.underMouse?.backingScaleFactor ?? 2
        return QRGenerator.image(for: message, minimumPixels: Int(side * scale))
    }

    private func makePanel() -> CheesePanel {
        let panel = CheesePanel(rootView: QRPanelView(model: model))
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    // MARK: Content

    @concurrent
    static func resource(for content: ShareContent) async throws -> ShareResource {
        let download = ShareRules.Resource.download.rawValue
        switch content {
        case let .text(text):
            return ShareResource(contentType: "text/plain; charset=utf-8", body: .data(Data(text.utf8)), items: [.text(text)])
        case let .image(png):
            let name = "Image.png"
            return ShareResource(
                contentType: "image/png", body: .data(png), attachmentName: name,
                items: [.file(.init(name: name, size: Int64(png.count), mimeType: "image/png", href: download))]
            )
        case let .file(url):
            let type = mimeType(of: url)
            return ShareResource(
                contentType: type, body: .file(url), attachmentName: url.lastPathComponent,
                items: [.file(.init(name: url.lastPathComponent, size: fileSize(of: url), mimeType: type, href: download))]
            )
        case let .archive(urls):
            let archive = try await ShareArchiver.archive(urls)
            return ShareResource(
                contentType: "application/zip", body: .file(archive.zip),
                attachmentName: archive.zip.lastPathComponent, temporaryFiles: [archive.temporaryFolder],
                items: urls.map { .file(.init(name: $0.lastPathComponent, size: fileSize(of: $0), mimeType: mimeType(of: $0))) },
                isArchive: true
            )
        }
    }

    private nonisolated static func mimeType(of url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Nil for a folder.
    private nonisolated static func fileSize(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { return nil }
        return Int64(values?.fileSize ?? 0)
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

struct QRPanelView: View {
    let model: QRPanelModel

    var body: some View {
        VStack(spacing: 0) {
            CheeseToolbar {
                Image(systemName: ModuleID.qr.symbol)
                    .foregroundStyle(.tint)
                Text("Clipboard as QR")
                    .font(DesignTokens.Typography.heading)
            } trailing: {
                CheeseIconButton(symbol: "xmark", help: "Close") { model.onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            content
                .padding(DesignTokens.Spacing.panel)
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .cheesePanelBackground()
    }

    private var width: CGFloat {
        if case let .code(_, side, _, _) = model.content { return max(380, side + 72) }
        return 380
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .preparing:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 240)
        case let .message(title, detail, symbol):
            CheeseEmptyState(symbol: symbol, title: title, detail: detail)
                .frame(maxWidth: .infinity)
        case let .code(image, side, preview, share):
            VStack(spacing: DesignTokens.Spacing.large) {
                HStack(spacing: DesignTokens.Spacing.small) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(share == nil ? "In the code" : "Ready to Share")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(preview)
                            .font(DesignTokens.Typography.secondary.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DesignTokens.Spacing.medium)
                .frame(minHeight: 40)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
                ShareLinkCard(
                    code: image, side: side, link: share?.url,
                    caption: share == nil ? "Scan with your phone's camera" : nil,
                    expiresAt: share?.expiresAt,
                    onStop: share.map { share in { model.onStopSharing(share.token) } }
                )
            }
        }
    }
}
