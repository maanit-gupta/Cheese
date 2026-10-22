import Foundation
import Network
import os

/// A parsed HTTP/1.1 request head.
struct HTTPRequest: Sendable, Equatable {
    var method: String
    /// The request target exactly as sent: path plus query.
    var target: String
    /// The target's path, without the query.
    var path: String
    /// Query parameters, percent-decoded. A repeated name keeps its last value.
    var query: [String: String]
    /// Header values by lowercased name.
    var headers: [String: String]
    /// The client's IP address.
    var remoteAddress: String?

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// What a handler answers with. Every response closes the connection after it's sent.
struct HTTPResponse: Sendable {
    enum Body: Sendable {
        case empty
        case data(Data)
        /// Streamed from disk in 1 MB pieces.
        case file(URL)
    }

    var status: Int
    var headers: [(String, String)] = []
    var body: Body = .empty

    /// A status with its reason as a short plain-text body.
    static func status(_ status: Int) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [("Content-Type", "text/plain; charset=utf-8")],
            body: .data(Data("\(status) \(HTTPMessage.reason(for: status))\n".utf8))
        )
    }

    static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        guard let data = try? JSONEncoder().encode(value) else { return .status(500) }
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: .data(data))
    }

    static func html(_ html: String) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: [("Content-Type", "text/html; charset=utf-8"), ("Cache-Control", "no-store")],
            body: .data(Data(html.utf8))
        )
    }
}

enum HTTPBodyError: LocalizedError {
    case tooLarge
    case malformedChunk
    case truncated

    var errorDescription: String? {
        switch self {
        case .tooLarge: "The request body is too large."
        case .malformedChunk: "The request body's chunked encoding is malformed."
        case .truncated: "The connection closed before the whole body arrived."
        }
    }
}

/// Bytes arriving on a connection. A protocol so request bodies are tested without a socket.
protocol HTTPByteSource: AnyObject, Sendable {
    /// Up to `count` bytes, or nil once the peer has closed.
    func read(upTo count: Int) async throws -> Data?
    /// One line without its CRLF, or nil once the peer has closed.
    func readLine(limit: Int) async throws -> Data?
}

/// A request's body, read on demand: by Content-Length, chunked, or none at all.
final class HTTPRequestBody: @unchecked Sendable {
    enum Framing: Equatable, Sendable {
        case none
        case length(Int64)
        case chunked
    }

    let framing: Framing
    private let source: any HTTPByteSource
    // Only touched by the one task serving the connection.
    private var remaining: Int64 = 0
    private var chunkRemaining: Int64 = 0
    private var isFinished = false

    init(framing: Framing, source: any HTTPByteSource) {
        self.framing = framing
        self.source = source
        switch framing {
        case .none: isFinished = true
        case let .length(length):
            remaining = length
            isFinished = length == 0
        case .chunked: break
        }
    }

    /// The declared length, when the client sent one.
    var declaredLength: Int64? {
        if case let .length(length) = framing { return length }
        return framing == .none ? 0 : nil
    }

    /// The next piece of the body, or nil when it's all been read.
    func next() async throws -> Data? {
        guard !isFinished else { return nil }
        switch framing {
        case .none:
            return nil
        case .length:
            guard let data = try await source.read(upTo: Int(min(remaining, 1 << 20))) else { throw HTTPBodyError.truncated }
            remaining -= Int64(data.count)
            isFinished = remaining <= 0
            return data
        case .chunked:
            if chunkRemaining == 0 {
                guard let line = try await source.readLine(limit: 1024) else { throw HTTPBodyError.truncated }
                guard let size = Self.chunkSize(line) else { throw HTTPBodyError.malformedChunk }
                if size == 0 {
                    // Trailers, up to the blank line.
                    while let trailer = try await source.readLine(limit: 8192), !trailer.isEmpty {}
                    isFinished = true
                    return nil
                }
                chunkRemaining = size
            }
            guard let data = try await source.read(upTo: Int(min(chunkRemaining, 1 << 20))) else { throw HTTPBodyError.truncated }
            chunkRemaining -= Int64(data.count)
            if chunkRemaining == 0 {
                // The CRLF that ends the chunk.
                guard let end = try await source.readLine(limit: 2), end.isEmpty else { throw HTTPBodyError.malformedChunk }
            }
            return data
        }
    }

    /// The whole body in memory, refusing anything over `limit` bytes.
    func collect(limit: Int) async throws -> Data {
        if let declared = declaredLength, declared > limit {
            throw HTTPBodyError.tooLarge
        }
        var data = Data()
        while let piece = try await next() {
            data.append(piece)
            if data.count > limit {
                throw HTTPBodyError.tooLarge
            }
        }
        return data
    }

    /// A chunk-size line: hex digits, optionally followed by `;extensions`.
    static func chunkSize(_ line: Data) -> Int64? {
        guard let text = String(data: line, encoding: .ascii) else { return nil }
        let hex = text.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !hex.isEmpty, hex.count <= 15, hex.allSatisfy(\.isHexDigit) else { return nil }
        return Int64(hex, radix: 16)
    }
}

extension HTTPMessage {
    /// The method, target, query and headers of a request head, or nil when it's malformed.
    static func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let line = parseHead(data),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        var headers: [String: String] = [:]
        for headerLine in text.components(separatedBy: "\r\n").dropFirst() {
            guard !headerLine.isEmpty else { break }
            guard let colon = headerLine.firstIndex(of: ":") else { return nil }
            let name = headerLine[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = headerLine[headerLine.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            headers[name] = value
        }
        let parts = line.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts.first ?? "")
        let query = parts.count > 1 ? parseQuery(String(parts[1])) : [:]
        return HTTPRequest(method: line.method, target: line.path, path: path, query: query, headers: headers)
    }

    static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first else { continue }
            let decode = { (value: Substring) in
                value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(value)
            }
            result[decode(rawName)] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return result
    }

    /// How the request's body is framed, or nil when its Content-Length is invalid.
    static func framing(of request: HTTPRequest) -> HTTPRequestBody.Framing? {
        if request.header("transfer-encoding")?.lowercased().contains("chunked") == true {
            return .chunked
        }
        guard let length = request.header("content-length") else { return HTTPRequestBody.Framing.none }
        guard let value = Int64(length), value >= 0 else { return nil }
        return .length(value)
    }
}

/// A connection read through a buffer, so bytes that arrive with the request head aren't lost, and
/// closed when nothing arrives for `idleTimeout` (stalled uploads).
final class HTTPConnectionStream: HTTPByteSource, @unchecked Sendable {
    let connection: NWConnection
    private let idleTimeout: Duration
    // Only touched by the one task serving the connection.
    private var buffer = Data()
    private var isClosed = false

    init(connection: NWConnection, idleTimeout: Duration) {
        self.connection = connection
        self.idleTimeout = idleTimeout
    }

    /// Fills the buffer with whatever arrives next. False once the peer has closed.
    private func fill() async throws -> Bool {
        guard !isClosed else { return false }
        let connection = connection
        let timeout = idleTimeout
        let timer = Task {
            try await Task.sleep(for: timeout)
            connection.cancel()
        }
        defer { timer.cancel() }
        let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
        guard let chunk else {
            isClosed = true
            return false
        }
        buffer.append(chunk)
        return true
    }

    /// The request head, through its blank line, or nil when the peer closed first or it's too big.
    func readHead(limit: Int) async throws -> Data? {
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.range(of: terminator) {
                let head = buffer[buffer.startIndex..<range.upperBound]
                buffer = Data(buffer[range.upperBound...])
                return Data(head)
            }
            guard buffer.count < limit, try await fill() else { return nil }
        }
    }

    func read(upTo count: Int) async throws -> Data? {
        if buffer.isEmpty, try await !fill() {
            return nil
        }
        let piece = buffer.prefix(count)
        buffer = Data(buffer.dropFirst(piece.count))
        return Data(piece)
    }

    func readLine(limit: Int) async throws -> Data? {
        let crlf = Data("\r\n".utf8)
        while true {
            if let range = buffer.range(of: crlf) {
                let line = buffer[buffer.startIndex..<range.lowerBound]
                buffer = Data(buffer[range.upperBound...])
                return Data(line)
            }
            guard buffer.count <= limit + 2 else { throw HTTPBodyError.malformedChunk }
            guard try await fill() else { return nil }
        }
    }

    func send(_ data: Data) async throws {
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

    func send(_ response: HTTPResponse) async throws {
        var headers = response.headers
        headers.append(("Connection", "close"))
        switch response.body {
        case .empty:
            headers.append(("Content-Length", "0"))
            try await send(HTTPMessage.responseHead(status: response.status, headers: headers))
        case let .data(data):
            headers.append(("Content-Length", "\(data.count)"))
            try await send(HTTPMessage.responseHead(status: response.status, headers: headers) + data)
        case let .file(url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            headers.append(("Content-Length", "\(size)"))
            try await send(HTTPMessage.responseHead(status: response.status, headers: headers))
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try await send(chunk)
            }
        }
    }
}

enum HTTPServerError: LocalizedError {
    case listenerFailed(String)
    case noPort

    var errorDescription: String? {
        switch self {
        case let .listenerFailed(reason): "Couldn't start sharing: \(reason)"
        case .noPort: "Couldn't start sharing: no port was assigned."
        }
    }
}

/// A small HTTP/1.1 server on Network.framework. It listens only on one address (the LAN
/// interface, never every interface), hands each request to `handler`, and closes the connection
/// after answering. The QR share link and Cheese Share both run on it.
@MainActor
final class HTTPServer {
    typealias Handler = @Sendable (HTTPRequest, HTTPRequestBody) async -> HTTPResponse

    /// Called when the listener fails after it started, for example when the network goes away.
    var onFailure: (String) -> Void = { _ in }
    private(set) var port: UInt16?
    private(set) var address: String?
    private let handler: Handler
    private let idleTimeout: Duration
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(idleTimeout: Duration = .seconds(60), handler: @escaping Handler) {
        self.idleTimeout = idleTimeout
        self.handler = handler
    }

    var isRunning: Bool { listener != nil }

    /// Starts listening on `address` and returns the port: `preferredPort` when it's free,
    /// otherwise any. With `identity`, it speaks HTTPS with that certificate. Already running on
    /// that address, it just returns the port.
    func start(on address: String, preferredPort: UInt16? = nil, identity: sec_identity_t? = nil) async throws -> UInt16 {
        if listener != nil, self.address == address, let port {
            return port
        }
        stop()
        if let preferredPort, let port = NWEndpoint.Port(rawValue: preferredPort),
           let bound = try? await listen(on: address, port: port, identity: identity) {
            return bound
        }
        return try await listen(on: address, port: .any, identity: identity)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        address = nil
        port = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func listen(on address: String, port: NWEndpoint.Port, identity: sec_identity_t?) async throws -> UInt16 {
        let parameters: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw HTTPServerError.listenerFailed(error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
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
                        listener.cancel()
                        continuation.resume(throwing: HTTPServerError.listenerFailed(error.localizedDescription))
                    case .cancelled:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: HTTPServerError.listenerFailed("cancelled"))
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
        }
        guard let bound = listener.port?.rawValue else {
            listener.cancel()
            throw HTTPServerError.noPort
        }
        self.listener = listener
        self.address = address
        self.port = bound
        return bound
    }

    private func listenerChanged(_ state: NWListener.State) {
        if case let .failed(error) = state {
            Logger.share.error("HTTP listener failed: \(error.localizedDescription, privacy: .public)")
            stop()
            onFailure(error.localizedDescription)
        }
    }

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
        let stream = HTTPConnectionStream(connection: connection, idleTimeout: idleTimeout)
        let handler = handler
        Task {
            await Self.serve(stream, handler: handler)
            connection.cancel()
        }
    }

    @concurrent
    private static func serve(_ stream: HTTPConnectionStream, handler: Handler) async {
        do {
            guard let head = try await stream.readHead(limit: HTTPMessage.maxHeadBytes) else { return }
            guard var request = HTTPMessage.parseRequest(head), let framing = HTTPMessage.framing(of: request) else {
                try await stream.send(.status(400))
                return
            }
            request.remoteAddress = remoteAddress(of: stream.connection)
            if request.header("expect")?.lowercased() == "100-continue" {
                try await stream.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
            }
            let response = await handler(request, HTTPRequestBody(framing: framing, source: stream))
            try await stream.send(response)
        } catch {
            Logger.share.debug("Connection ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func remoteAddress(of connection: NWConnection) -> String? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        switch host {
        case let .ipv4(address): return "\(address)".split(separator: "%").first.map(String.init)
        case let .ipv6(address): return "\(address)".split(separator: "%").first.map(String.init)
        case let .name(name, _): return name
        @unknown default: return nil
        }
    }
}
