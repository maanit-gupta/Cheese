import Foundation

/// What one share link serves, ready to send.
struct ShareResource: Sendable {
    enum Body: Sendable {
        case data(Data)
        case file(URL)
    }

    var contentType: String
    var body: Body
    /// Set for downloads: the name the phone saves the file under.
    var attachmentName: String?
    /// Temp files made for this share (zips), deleted when it ends.
    var temporaryFiles: [URL] = []
    /// What the link's page lists. Its files download from `download` under the link.
    var items: [BrowserSharePageRenderer.Item] = []
    /// The download is a zip of every listed item.
    var isArchive = false
}

/// One live share link: a random token, what it serves, and when it stops working.
struct ShareSession: Sendable, Identifiable {
    let token: String
    let resource: ShareResource
    let expiresAt: Date

    var id: String { token }

    func isExpired(at now: Date) -> Bool {
        now >= expiresAt
    }
}

/// The rules for share links: token shape, lifetime, and which requests get what.
enum ShareRules {
    /// Links stop working this long after they're made.
    static let lifetime: TimeInterval = 10 * 60
    /// 128 random bits, as hex.
    static let tokenLength = 32

    static func makeToken<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        let high = generator.next() as UInt64
        let low = generator.next() as UInt64
        return String(format: "%016llx%016llx", high, low)
    }

    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return makeToken(using: &generator)
    }

    /// The token a request path names, if it has exactly the shape `/<token>`.
    static func token(fromPath path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let token = path.dropFirst()
        guard token.count == tokenLength, token.allSatisfy(\.isHexDigit), token == token.lowercased() else { return nil }
        return String(token)
    }

    /// The live session a path names. Anything else, including an expired link, is nil (a 404).
    static func session(forPath path: String, in sessions: [ShareSession], now: Date) -> ShareSession? {
        guard let token = token(fromPath: path) else { return nil }
        return sessions.first { $0.token == token && !$0.isExpired(at: now) }
    }

    /// What a link serves: its page, the page's polled state, and the shared item itself.
    enum Resource: String, Equatable, Sendable {
        case page = ""
        case state
        case download
    }

    /// The token and resource a path names: `/<token>`, `/<token>/`, `/<token>/state` or
    /// `/<token>/download`. Anything else is nil.
    static func parse(path: String) -> (token: String, resource: Resource)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"), let first = parts.first, let token = token(fromPath: "/" + first) else { return nil }
        switch parts.count {
        case 1: return (token, .page)
        case 2: return Resource(rawValue: String(parts[parts.startIndex + 1])).map { (token, $0) }
        default: return nil
        }
    }
}

/// The parts of HTTP/1.1 the share server needs: a request line in, a status and headers out.
enum HTTPMessage {
    struct RequestHead: Equatable {
        var method: String
        var path: String
    }

    enum Route: Equatable {
        case serve(token: String, ShareRules.Resource)
        case status(Int)
    }

    /// Requests larger than this before the blank line are refused.
    static let maxHeadBytes = 16 * 1024
    private static let headTerminator = Data("\r\n\r\n".utf8)

    /// True once `data` holds the whole request head.
    static func hasCompleteHead(_ data: Data) -> Bool {
        data.range(of: headTerminator) != nil
    }

    /// The method and path of a request, or nil when the request line is malformed.
    static func parseHead(_ data: Data) -> RequestHead? {
        guard let end = data.range(of: Data("\r\n".utf8)),
              let line = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), !parts[0].isEmpty, parts[1].hasPrefix("/") else { return nil }
        return RequestHead(method: String(parts[0]), path: String(parts[1]))
    }

    /// GET only, for a live share's page, state or download; everything else is an error status.
    static func route(_ head: RequestHead?, sessions: [ShareSession], now: Date) -> Route {
        guard let head else { return .status(400) }
        guard head.method == "GET" else { return .status(405) }
        guard let (token, resource) = ShareRules.parse(path: head.path),
              let session = sessions.first(where: { $0.token == token && !$0.isExpired(at: now) })
        else { return .status(404) }
        return .serve(token: session.token, resource)
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        default: "Error"
        }
    }

    static func responseHead(status: Int, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(for: status))\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// `attachment` with an ASCII fallback name and the real name percent-encoded (RFC 6266).
    static func contentDisposition(attachmentName name: String) -> String {
        let fallback = String(name.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && scalar.value >= 0x20 && scalar != "\"" && scalar != "\\" ? Character(scalar) : "_"
        })
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? fallback
        return "attachment; filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
    }
}
