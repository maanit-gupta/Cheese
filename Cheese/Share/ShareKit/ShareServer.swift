import Foundation
import os

/// Share links for Show Clipboard as QR, on `HTTPServer`. It listens only on the LAN address,
/// serves GET for live share tokens and nothing else, and shuts down when the last share ends.
@MainActor
final class ShareServer {
    /// Called when a share ends, with its token.
    var onShareEnded: (String) -> Void = { _ in }

    private var sessions: [String: ShareSession] = [:]
    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private lazy var http: HTTPServer = {
        let server = HTTPServer { [weak self] request, _ in
            await self?.respond(to: request) ?? .status(404)
        }
        server.onFailure = { [weak self] _ in self?.stopAll() }
        return server
    }()

    var hasActiveShares: Bool { !sessions.isEmpty }

    /// Starts serving `resource` and returns its link. Starts the listener on `address` if needed.
    func share(_ resource: ShareResource, on address: String) async throws -> (session: ShareSession, url: URL) {
        if http.isRunning, http.address != address {
            // The Mac moved networks; links bound to the old address can't be reached anyway.
            stopAll()
        }
        let port = try await http.start(on: address)
        let session = ShareSession(token: ShareRules.makeToken(), resource: resource, expiresAt: .now.addingTimeInterval(ShareRules.lifetime))
        sessions[session.token] = session
        expiryTasks[session.token] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ShareRules.lifetime))
            guard !Task.isCancelled else { return }
            self?.stop(session.token)
        }
        guard let url = URL(string: "http://\(address):\(port)/\(session.token)") else {
            stop(session.token)
            throw HTTPServerError.noPort
        }
        Logger.qr.info("Sharing on port \(port), expires in \(Int(ShareRules.lifetime))s")
        return (session, url)
    }

    /// Ends one share and deletes its temp files. The listener stops with the last share.
    func stop(_ token: String) {
        guard let session = sessions.removeValue(forKey: token) else { return }
        expiryTasks.removeValue(forKey: token)?.cancel()
        for file in session.resource.temporaryFiles {
            try? FileManager.default.removeItem(at: file)
        }
        onShareEnded(token)
        if sessions.isEmpty {
            http.stop()
        }
    }

    func stopAll() {
        for token in Array(sessions.keys) {
            stop(token)
        }
        http.stop()
    }

    private func respond(to request: HTTPRequest) -> HTTPResponse {
        let head = HTTPMessage.RequestHead(method: request.method, path: request.target)
        switch HTTPMessage.route(head, sessions: Array(sessions.values), now: .now) {
        case let .status(status):
            return .status(status)
        case let .serve(token):
            guard let resource = sessions[token]?.resource else { return .status(404) }
            var headers: [(String, String)] = [("Content-Type", resource.contentType), ("Cache-Control", "no-store")]
            if let name = resource.attachmentName {
                headers.append(("Content-Disposition", HTTPMessage.contentDisposition(attachmentName: name)))
            }
            switch resource.body {
            case let .data(data): return HTTPResponse(status: 200, headers: headers, body: .data(data))
            case let .file(url): return HTTPResponse(status: 200, headers: headers, body: .file(url))
            }
        }
    }
}
