import CryptoKit
import Foundation
import Network
import Synchronization

/// A response read by `HTTPClient`.
struct HTTPClientResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
    /// SHA-256 of the server's certificate, hex, when the request went over TLS.
    var peerFingerprint: String?
}

enum HTTPClientError: LocalizedError {
    case couldNotConnect(String)
    case malformedResponse
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case let .couldNotConnect(reason): "Couldn't reach the device: \(reason)"
        case .malformedResponse: "The device sent a response Cheese couldn't read."
        case .responseTooLarge: "The device's response was too large."
        }
    }
}

/// The HTTP/1.1 client side of Cheese Share, on Network.framework. Over TLS it accepts the
/// self-signed certificates LocalSend devices use and reports the certificate's fingerprint, which
/// the caller checks against the fingerprint the device announced.
enum HTTPClient {
    struct Endpoint: Sendable, Equatable {
        var host: String
        var port: UInt16
        var usesTLS: Bool
    }

    /// Responses bigger than this are refused; LocalSend answers are small JSON.
    static let maxResponseBytes = 1 << 20

    @concurrent
    static func send(
        _ method: String,
        to endpoint: Endpoint,
        target: String,
        headers: [(String, String)] = [],
        body: HTTPResponse.Body = .empty,
        timeout: Duration = .seconds(30),
        identity: ShareIdentity? = nil,
        onProgress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> HTTPClientResponse {
        let fingerprint = Mutex<String?>(nil)
        let parameters: NWParameters
        if endpoint.usesTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first {
                    let der = SecCertificateCopyData(leaf) as Data
                    fingerprint.withLock { $0 = TLSIdentity.fingerprint(ofCertificate: der) }
                }
                // Self-signed by design; identity is the fingerprint, checked by the caller.
                complete(true)
            }, .global())
            // Present our certificate too, so the device can tell who's sending.
            if let local = identity?.secIdentity {
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
            }
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { throw HTTPClientError.couldNotConnect("bad port") }
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
        defer { connection.cancel() }
        try await connect(connection, timeout: timeout)

        let stream = HTTPConnectionStream(connection: connection, idleTimeout: timeout)
        var head: [(String, String)] = [("Host", "\(endpoint.host):\(endpoint.port)"), ("Connection", "close")] + headers
        let hostLine = "\(method) \(target) HTTP/1.1\r\n"
        switch body {
        case .empty:
            head.append(("Content-Length", "0"))
            try await stream.send(requestHead(hostLine, head))
        case let .data(data):
            head.append(("Content-Length", "\(data.count)"))
            try await stream.send(requestHead(hostLine, head) + data)
            onProgress(Int64(data.count))
        case let .file(url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            head.append(("Content-Length", "\(size)"))
            try await stream.send(requestHead(hostLine, head))
            var sent: Int64 = 0
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try await stream.send(chunk)
                sent += Int64(chunk.count)
                onProgress(sent)
            }
        }

        guard let responseHead = try await stream.readHead(limit: HTTPMessage.maxHeadBytes),
              let (status, responseHeaders) = HTTPMessage.parseResponseHead(responseHead)
        else { throw HTTPClientError.malformedResponse }
        var data = Data()
        if let length = responseHeaders["content-length"].flatMap(Int.init) {
            guard length <= maxResponseBytes else { throw HTTPClientError.responseTooLarge }
            while data.count < length, let piece = try await stream.read(upTo: length - data.count) {
                data.append(piece)
            }
        } else if responseHeaders["transfer-encoding"]?.lowercased().contains("chunked") == true {
            data = try await HTTPRequestBody(framing: .chunked, source: stream).collect(limit: maxResponseBytes)
        } else if status != 204 {
            while let piece = try await stream.read(upTo: 1 << 16) {
                data.append(piece)
                guard data.count <= maxResponseBytes else { throw HTTPClientError.responseTooLarge }
            }
        }
        return HTTPClientResponse(status: status, headers: responseHeaders, body: data, peerFingerprint: fingerprint.withLock { $0 })
    }

    private static func requestHead(_ line: String, _ headers: [(String, String)]) -> Data {
        var text = line
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        return Data((text + "\r\n").utf8)
    }

    private static func connect(_ connection: NWConnection, timeout: Duration) async throws {
        let timer = Task {
            try await Task.sleep(for: timeout)
            connection.cancel()
        }
        defer { timer.cancel() }
        let resumed = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let finish: @Sendable (Result<Void, any Error>) -> Void = { result in
                guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case let .waiting(error), let .failed(error): finish(.failure(HTTPClientError.couldNotConnect(error.localizedDescription)))
                case .cancelled: finish(.failure(HTTPClientError.couldNotConnect("timed out")))
                default: break
                }
            }
            connection.start(queue: .global())
        }
        connection.stateUpdateHandler = nil
    }
}

extension HTTPMessage {
    /// A response's status and headers (lowercased names), or nil when the head is malformed.
    static func parseResponseHead(_ data: Data) -> (status: Int, headers: [String: String])? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]), (100...599).contains(status) else { return nil }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (status, headers)
    }
}
