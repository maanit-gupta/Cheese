import Foundation
import os

/// The no-app way in: a phone scans the Share panel's QR code and gets a page where it can upload
/// files, photos and text to this Mac, and download what the Mac is offering. The link's random
/// token is the consent: anyone with it can use the page until Cheese Share stops listening, when
/// a new token is made.
@MainActor
final class BrowserTransfer {
    struct Hooks {
        var destination: @MainActor () -> URL
        var maxBytes: @MainActor () -> Int64
        var onText: @MainActor (_ text: String) -> Void
        var onFileReceived: @MainActor (_ file: URL) -> Void
        /// The name the page says it's connected to.
        var deviceName: @MainActor () -> String = { Preferences().shareDeviceName }
    }

    /// Texts posted from the page larger than this are refused.
    static let maxTextBytes = 1 << 20

    private(set) var token = ShareRules.makeToken()
    /// What the page offers for download.
    private(set) var offered: [OutgoingItem] = []
    /// When the link stops working: nil while the Share panel is open, since it lasts until then.
    var expiresAt: Date?
    private let hooks: Hooks
    /// The zip behind Download All, kept until the files on offer change.
    private var zip: (files: [URL], archive: ShareArchiver.Archive)?

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    /// A fresh token, so old links stop working. Called when Cheese Share stops.
    func reset() {
        token = ShareRules.makeToken()
        offered = []
        expiresAt = nil
        discardZip()
    }

    func offer(_ items: [OutgoingItem]) {
        let new = items.filter { item in !offered.contains { $0.content == item.content } }
        offered.append(contentsOf: new)
    }

    func withdraw(_ id: OutgoingItem.ID) {
        offered.removeAll { $0.id == id }
    }

    func url(address: String, port: UInt16) -> URL? {
        URL(string: "http://\(address):\(port)/\(token)/")
    }

    /// The route under this session's token, or nil when the path isn't ours.
    nonisolated static func route(path: String, token: String) -> String? {
        let prefix = "/\(token)"
        guard path == prefix || path.hasPrefix(prefix + "/") else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        return rest.isEmpty ? "/" : rest
    }

    func handles(_ path: String) -> Bool {
        Self.route(path: path, token: token) != nil
    }

    func handle(_ request: HTTPRequest, body: HTTPRequestBody) async -> HTTPResponse {
        guard let route = Self.route(path: request.path, token: token) else { return .status(404) }
        switch (request.method, route) {
        case ("GET", "/"):
            return .html(BrowserSharePageRenderer.html(page()))
        case ("GET", "/state"):
            return .json(BrowserSharePageRenderer.state(page()))
        case ("GET", "/download-all"):
            return await downloadAll()
        case ("POST", "/text"):
            guard let data = try? await body.collect(limit: Self.maxTextBytes), let text = String(data: data, encoding: .utf8),
                  text.contains(where: { !$0.isWhitespace })
            else { return .status(400) }
            hooks.onText(text)
            return HTTPResponse(status: 204)
        case ("POST", "/upload"):
            return await upload(request, body: body)
        default:
            if request.method == "GET", route.hasPrefix("/download/") {
                return download(String(route.dropFirst("/download/".count)))
            }
            return .status(request.method == "GET" || request.method == "POST" ? 404 : 405)
        }
    }

    /// What the page shows right now.
    func page(now: Date = .now) -> BrowserSharePageRenderer.Page {
        let items = offered.map { item -> BrowserSharePageRenderer.Item in
            switch item.content {
            case let .text(text):
                return .text(text)
            case .file:
                return .file(.init(name: item.name, size: item.size, mimeType: item.mimeType, href: "download/\(item.id.uuidString)"))
            }
        }
        return BrowserSharePageRenderer.Page(
            deviceName: hooks.deviceName(),
            basePath: "/\(token)/",
            items: items,
            downloadAllHref: offeredFiles.count > 1 ? "download-all" : nil,
            acceptsUploads: true,
            expiresIn: expiresAt.map { Int($0.timeIntervalSince(now).rounded(.up)) }
        )
    }

    private var offeredFiles: [URL] {
        offered.compactMap { item in
            if case let .file(url) = item.content { return url }
            return nil
        }
    }

    private func downloadAll() async -> HTTPResponse {
        let files = offeredFiles
        guard files.count > 1 else { return .status(404) }
        if zip?.files != files {
            do {
                let archive = try await ShareArchiver.archive(files)
                if zip?.files == files {
                    // Another request zipped the same files meanwhile.
                    try? FileManager.default.removeItem(at: archive.temporaryFolder)
                } else {
                    discardZip()
                    zip = (files, archive)
                }
            } catch {
                Logger.share.error("Zipping for Download All failed: \(error.localizedDescription, privacy: .public)")
                return .status(500)
            }
        }
        guard let zip else { return .status(404) }
        return HTTPResponse(status: 200, headers: [
            ("Content-Type", "application/zip"),
            ("Content-Disposition", HTTPMessage.contentDisposition(attachmentName: zip.archive.zip.lastPathComponent)),
            ("Cache-Control", "no-store"),
        ], body: .file(zip.archive.zip))
    }

    private func discardZip() {
        if let zip {
            try? FileManager.default.removeItem(at: zip.archive.temporaryFolder)
        }
        zip = nil
    }

    private func download(_ id: String) -> HTTPResponse {
        guard let item = offered.first(where: { $0.id.uuidString == id }) else { return .status(404) }
        switch item.content {
        case let .file(url):
            guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else { return .status(404) }
            return HTTPResponse(status: 200, headers: [
                ("Content-Type", item.mimeType),
                ("Content-Disposition", HTTPMessage.contentDisposition(attachmentName: url.lastPathComponent)),
                ("Cache-Control", "no-store"),
            ], body: .file(url))
        case let .text(text):
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/plain; charset=utf-8")], body: .data(Data(text.utf8)))
        }
    }

    private func upload(_ request: HTTPRequest, body: HTTPRequestBody) async -> HTTPResponse {
        guard let name = request.query["name"], !name.isEmpty else { return .status(400) }
        let folder = hooks.destination()
        let partial = ReceivedFileWriter.partialURL(in: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await ReceivedFileWriter.write(body, to: partial, expectedSize: body.declaredLength, maxSize: hooks.maxBytes(), sha256: nil) { _ in }
            let file = try ReceivedFileWriter.finish(partial, named: name, in: folder)
            hooks.onFileReceived(file)
            return HTTPResponse(status: 204)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            Logger.share.error("Browser upload failed: \(error.localizedDescription, privacy: .public)")
            return .status(error as? ReceiveError == .tooLarge ? 413 : 400)
        }
    }
}
