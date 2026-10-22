import Foundation
import Network
import os

enum ShareServerError: LocalizedError {
    case listenerFailed(String)
    case noPort

    var errorDescription: String? {
        switch self {
        case let .listenerFailed(reason): "Couldn't start sharing: \(reason)"
        case .noPort: "Couldn't start sharing: no port was assigned."
        }
    }
}

/// A tiny HTTP/1.1 server for share links. It listens only on the LAN address, serves GET for
/// live share tokens and nothing else, and shuts down when the last share ends.
@MainActor
final class ShareServer {
    /// Called when a share ends, with its token.
    var onShareEnded: (String) -> Void = { _ in }

    private var listener: NWListener?
    private var boundAddress: String?
    private var port: UInt16?
    private var sessions: [String: ShareSession] = [:]
    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    var hasActiveShares: Bool { !sessions.isEmpty }

    /// Starts serving `resource` and returns its link. Starts the listener on `address` if needed.
    func share(_ resource: ShareResource, on address: String) async throws -> (session: ShareSession, url: URL) {
        if boundAddress != address {
            // The Mac moved networks; links bound to the old address can't be reached anyway.
            stopAll()
        }
        let port = try await startListenerIfNeeded(on: address)
        let session = ShareSession(token: ShareRules.makeToken(), resource: resource, expiresAt: .now.addingTimeInterval(ShareRules.lifetime))
        sessions[session.token] = session
        expiryTasks[session.token] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ShareRules.lifetime))
            guard !Task.isCancelled else { return }
            self?.stop(session.token)
        }
        guard let url = URL(string: "http://\(address):\(port)/\(session.token)") else {
            stop(session.token)
            throw ShareServerError.noPort
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
            stopListener()
        }
    }

    func stopAll() {
        for token in Array(sessions.keys) {
            stop(token)
        }
        stopListener()
    }

    // MARK: Listener

    private func startListenerIfNeeded(on address: String) async throws -> UInt16 {
        if listener != nil, let port {
            return port
        }
        let parameters = NWParameters.tcp
        // Bind to the LAN interface only, never to every interface.
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ShareServerError.listenerFailed(error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        boundAddress = address

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = { [weak self] state in
                            MainActor.assumeIsolated { self?.listenerChanged(state) }
                        }
                        continuation.resume()
                    case let .failed(error):
                        listener.stateUpdateHandler = nil
                        self?.stopListener()
                        continuation.resume(throwing: ShareServerError.listenerFailed(error.localizedDescription))
                    case .cancelled:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: ShareServerError.listenerFailed("cancelled"))
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
        }
        guard let port = listener.port?.rawValue else {
            stopListener()
            throw ShareServerError.noPort
        }
        self.port = port
        return port
    }

    private func listenerChanged(_ state: NWListener.State) {
        if case let .failed(error) = state {
            Logger.qr.error("Share listener failed: \(error.localizedDescription, privacy: .public)")
            stopAll()
        }
    }

    private func stopListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        boundAddress = nil
        port = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                MainActor.assumeIsolated { _ = self?.connections.removeValue(forKey: key) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        Task { [weak self] in
            await self?.serve(connection)
            connection.cancel()
        }
    }

    private func serve(_ connection: NWConnection) async {
        var head = Data()
        do {
            while !HTTPMessage.hasCompleteHead(head) {
                guard head.count < HTTPMessage.maxHeadBytes,
                      let chunk = try await Self.receive(on: connection), !chunk.isEmpty
                else { return }
                head.append(chunk)
            }
            let route = HTTPMessage.route(HTTPMessage.parseHead(head), sessions: Array(sessions.values), now: .now)
            switch route {
            case let .status(status):
                let body = Data("\(status) \(HTTPMessage.reason(for: status))\n".utf8)
                try await Self.send(HTTPMessage.responseHead(status: status, headers: [
                    ("Content-Type", "text/plain; charset=utf-8"),
                    ("Content-Length", "\(body.count)"),
                    ("Connection", "close"),
                ]) + body, on: connection)
            case let .serve(token):
                guard let resource = sessions[token]?.resource else { return }
                try await Self.send(resource, on: connection)
            }
        } catch {
            Logger.qr.debug("Share connection ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    @concurrent
    private static func send(_ resource: ShareResource, on connection: NWConnection) async throws {
        var headers: [(String, String)] = [
            ("Content-Type", resource.contentType),
            ("Cache-Control", "no-store"),
            ("Connection", "close"),
        ]
        if let name = resource.attachmentName {
            headers.append(("Content-Disposition", HTTPMessage.contentDisposition(attachmentName: name)))
        }
        switch resource.body {
        case let .data(data):
            headers.append(("Content-Length", "\(data.count)"))
            try await send(HTTPMessage.responseHead(status: 200, headers: headers) + data, on: connection)
        case let .file(url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            headers.append(("Content-Length", "\(size)"))
            try await send(HTTPMessage.responseHead(status: 200, headers: headers), on: connection)
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try await send(chunk, on: connection)
            }
        }
    }

    @concurrent
    private static func receive(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? (isComplete ? nil : Data()))
                }
            }
        }
    }

    @concurrent
    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
