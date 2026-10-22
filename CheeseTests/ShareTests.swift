import CryptoKit
import Foundation
import Testing
@testable import Cheese

private final class ShareBundleToken {}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle(for: ShareBundleToken.self).url(forResource: name, withExtension: "json", subdirectory: "Fixtures/LocalSend"))
    return try Data(contentsOf: url)
}

/// Bytes handed out in small pieces, like a slow connection.
private final class FakeByteSource: HTTPByteSource, @unchecked Sendable {
    private var buffer: Data
    private let pieceSize: Int

    init(_ text: String, pieceSize: Int = 3) {
        buffer = Data(text.utf8)
        self.pieceSize = pieceSize
    }

    func read(upTo count: Int) async throws -> Data? {
        guard !buffer.isEmpty else { return nil }
        let piece = buffer.prefix(min(count, pieceSize))
        buffer = Data(buffer.dropFirst(piece.count))
        return Data(piece)
    }

    func readLine(limit: Int) async throws -> Data? {
        guard let range = buffer.range(of: Data("\r\n".utf8)) else { return nil }
        let line = buffer[buffer.startIndex..<range.lowerBound]
        buffer = Data(buffer[range.upperBound...])
        return Data(line)
    }
}

// MARK: - HTTP

struct HTTPParsingTests {
    @Test func parsesHeadersQueryAndPath() throws {
        let head = Data("POST /api/localsend/v2/upload?sessionId=abc&fileId=a%20b&token=t+1 HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\nX-Thing:  spaced \r\n\r\n".utf8)
        let request = try #require(HTTPMessage.parseRequest(head))
        #expect(request.method == "POST")
        #expect(request.path == "/api/localsend/v2/upload")
        #expect(request.query == ["sessionId": "abc", "fileId": "a b", "token": "t 1"])
        #expect(request.header("content-length") == "12")
        #expect(request.header("X-THING") == "spaced")
        #expect(HTTPMessage.framing(of: request) == .length(12))
    }

    @Test func rejectsMalformedHeads() {
        #expect(HTTPMessage.parseRequest(Data("GET / HTTP/1.1\r\nno colon here\r\n\r\n".utf8)) == nil)
        #expect(HTTPMessage.parseRequest(Data("GET http://evil/ HTTP/1.1\r\n\r\n".utf8)) == nil)
    }

    @Test func framing() throws {
        func framing(_ headers: String) throws -> HTTPRequestBody.Framing? {
            let request = try #require(HTTPMessage.parseRequest(Data("POST / HTTP/1.1\r\n\(headers)\r\n".utf8)))
            return HTTPMessage.framing(of: request)
        }
        #expect(try framing("") == HTTPRequestBody.Framing.none)
        #expect(try framing("Transfer-Encoding: chunked\r\n") == .chunked)
        #expect(try framing("Content-Length: -1\r\n") == nil)
        #expect(try framing("Content-Length: abc\r\n") == nil)
    }

    @Test func readsBodiesByLength() async throws {
        let body = HTTPRequestBody(framing: .length(11), source: FakeByteSource("hello worldEXTRA"))
        #expect(try await body.collect(limit: 100) == Data("hello world".utf8))
    }

    @Test func readsChunkedBodies() async throws {
        let wire = "5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nTrailer: x\r\n\r\n"
        let body = HTTPRequestBody(framing: .chunked, source: FakeByteSource(wire))
        #expect(try await body.collect(limit: 100) == Data("hello world".utf8))
    }

    @Test func refusesOversizedAndTruncatedBodies() async {
        let big = HTTPRequestBody(framing: .length(50), source: FakeByteSource(String(repeating: "x", count: 50)))
        await #expect(throws: HTTPBodyError.tooLarge) { try await big.collect(limit: 10) }

        let short = HTTPRequestBody(framing: .length(20), source: FakeByteSource("only ten!!"))
        await #expect(throws: HTTPBodyError.truncated) { try await short.collect(limit: 100) }

        let bad = HTTPRequestBody(framing: .chunked, source: FakeByteSource("zz\r\nhello\r\n"))
        await #expect(throws: HTTPBodyError.malformedChunk) { try await bad.collect(limit: 100) }
    }

    @Test func chunkSizes() {
        #expect(HTTPRequestBody.chunkSize(Data("1a".utf8)) == 26)
        #expect(HTTPRequestBody.chunkSize(Data("FF;name=value".utf8)) == 255)
        #expect(HTTPRequestBody.chunkSize(Data("".utf8)) == nil)
        #expect(HTTPRequestBody.chunkSize(Data("-1".utf8)) == nil)
        #expect(HTTPRequestBody.chunkSize(Data(String(repeating: "f", count: 20).utf8)) == nil)
    }

    @Test func parsesResponseHeads() throws {
        let (status, headers) = try #require(HTTPMessage.parseResponseHead(Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".utf8)))
        #expect(status == 204)
        #expect(headers["content-length"] == "0")
        #expect(HTTPMessage.parseResponseHead(Data("SPDY 200\r\n\r\n".utf8)) == nil)
    }
}

// MARK: - Names and trust

struct FilenameSanitizerTests {
    @Test func stripsFoldersAndTraversal() {
        #expect(FilenameSanitizer.sanitize("photo.jpg") == "photo.jpg")
        #expect(FilenameSanitizer.sanitize("../../.ssh/authorized_keys") == "authorized_keys")
        #expect(FilenameSanitizer.sanitize("C:\\Users\\me\\report.docx") == "report.docx")
        #expect(FilenameSanitizer.sanitize("/etc/passwd") == "passwd")
        #expect(FilenameSanitizer.sanitize("..") == "File")
        #expect(FilenameSanitizer.sanitize("") == "File")
        #expect(FilenameSanitizer.sanitize("dir/") == "dir")
    }

    @Test func noHiddenOrControlCharacters() {
        #expect(FilenameSanitizer.sanitize(".bashrc") == "bashrc")
        #expect(FilenameSanitizer.sanitize("...hidden.txt") == "hidden.txt")
        #expect(FilenameSanitizer.sanitize("a\u{0}b\nc:d.txt") == "abcd.txt")
        #expect(FilenameSanitizer.sanitize("   ") == "File")
    }

    @Test func longNamesKeepTheirExtension() {
        let name = String(repeating: "é", count: 300) + ".pdf"
        let safe = FilenameSanitizer.sanitize(name)
        #expect(safe.utf8.count <= FilenameSanitizer.maxBytes)
        #expect(safe.hasSuffix(".pdf"))
    }

    @Test func neverOverwritesOrLeavesTheFolder() {
        let folder = URL(filePath: "/Users/me/Downloads", directoryHint: .isDirectory)
        let taken: Set<String> = ["/Users/me/Downloads/photo.jpg"]
        let url = FilenameSanitizer.destination(for: "../photo.jpg", in: folder) { taken.contains($0.path(percentEncoded: false)) }
        #expect(url.deletingLastPathComponent().path(percentEncoded: false) == "/Users/me/Downloads/")
        #expect(url.lastPathComponent == "photo 2.jpg")
    }
}

struct TrustStoreTests {
    private func makeStore() -> TrustStore {
        let defaults = UserDefaults(suiteName: "TrustStoreTests-\(UUID().uuidString)") ?? .standard
        return TrustStore(defaults: defaults)
    }

    @Test func trustsRemembersAndRevokes() {
        let store = makeStore()
        #expect(!store.isTrusted("ABC"))
        store.trust(fingerprint: "ABC", alias: "Pixel 8")
        #expect(store.isTrusted("abc"))
        store.trust(fingerprint: "abc", alias: "Pixel 8 Pro")
        #expect(store.devices.map(\.alias) == ["Pixel 8 Pro"])
        store.remove("ABC")
        #expect(!store.isTrusted("ABC"))
        #expect(store.devices.isEmpty)
    }

    @Test func emptyFingerprintsAreNeverTrusted() {
        let store = makeStore()
        store.trust(fingerprint: "", alias: "Anyone")
        #expect(store.devices.isEmpty)
        #expect(!store.isTrusted(""))
    }
}

// MARK: - LocalSend messages

struct LocalSendMessageTests {
    @Test func decodesTheSpecsAnnouncement() throws {
        let info = try #require(LocalSend.decode(LocalSend.DeviceInfo.self, from: fixture("announce")))
        #expect(info.alias == "Nice Orange")
        #expect(info.deviceType == .mobile)
        #expect(info.transport == .https)
        #expect(info.port == 53317)
        #expect(info.announce == true)
        let peer = try #require(LocalSendPeer(info: info, address: "192.168.1.20"))
        #expect(peer.endpoint == HTTPClient.Endpoint(host: "192.168.1.20", port: 53317, usesTLS: true))
        #expect(peer.symbol == "iphone")
    }

    @Test func decodesRegisterWithoutAnnounce() throws {
        let info = try #require(LocalSend.decode(LocalSend.DeviceInfo.self, from: fixture("register")))
        #expect(info.announce == nil)
        #expect(info.deviceType == .desktop)
    }

    @Test func decodesPrepareUpload() throws {
        let request = try #require(LocalSend.decode(LocalSend.PrepareUploadRequest.self, from: fixture("prepare-upload-request")))
        #expect(request.files.count == 2)
        let image = try #require(request.files["some file id"])
        #expect(image.fileName == "my image.png")
        #expect(image.size == 324_242)
        #expect(image.metadata?.modified == "2021-01-01T12:34:56Z")
        #expect(!image.isMessage)

        let response = try #require(LocalSend.decode(LocalSend.PrepareUploadResponse.self, from: fixture("prepare-upload-response")))
        #expect(response.sessionId == "mySessionId")
        #expect(response.files["someOtherFileId"] == "someOtherFileToken")
    }

    @Test func encodesProtocolAsTheWireKey() throws {
        let info = LocalSend.DeviceInfo(alias: "Mac", version: "2.2", fingerprint: "f", port: 53317, transport: .http)
        let json = try #require(String(data: LocalSend.encode(info), encoding: .utf8))
        #expect(json.contains("\"protocol\":\"http\""))
        #expect(!json.contains("transport"))
        #expect(LocalSend.decode(LocalSend.DeviceInfo.self, from: LocalSend.encode(info)) == info)
    }

    @Test func unknownDeviceTypesAreDesktops() throws {
        let json = Data(#"{"alias":"X","version":"2.0","fingerprint":"f","deviceType":"toaster"}"#.utf8)
        #expect(LocalSend.decode(LocalSend.DeviceInfo.self, from: json)?.deviceType == .desktop)
    }

    @Test func textIsSentAsAMessageFile() {
        let items: [OutgoingItem] = [.text("hello"), .file(URL(filePath: "/tmp/nothing-here.pdf"))]
        let files = LocalSendSender.fileInfos(for: items)
        let text = files[items[0].id.uuidString]
        #expect(text?.fileType == "text/plain")
        #expect(text?.preview == "hello")
        #expect(text?.size == 5)
        #expect(text?.isMessage == true)
        #expect(files[items[1].id.uuidString]?.fileType == "application/pdf")
    }

    @Test func queryIsPercentEncoded() {
        #expect(LocalSendSender.query(["b": "x y", "a": "1&2"]) == "a=1%262&b=x%20y")
    }

    @Test func certificateFingerprints() {
        let der = Data("certificate".utf8)
        let expected = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        #expect(TLSIdentity.fingerprint(ofCertificate: der) == expected)
        #expect(TLSIdentity.matches(expected.uppercased(), announced: expected))
        #expect(!TLSIdentity.matches(nil, announced: expected))
        #expect(!TLSIdentity.matches("other", announced: expected))
    }

    @Test func ourFingerprintIsStable() {
        let defaults = UserDefaults(suiteName: "Fingerprint-\(UUID().uuidString)") ?? .standard
        let first = TLSIdentity.fingerprint(defaults: defaults)
        #expect(first.count == 64)
        #expect(TLSIdentity.fingerprint(defaults: defaults) == first)
    }
}

// MARK: - Receive session

struct ReceiveSessionTests {
    private let sender = LocalSend.DeviceInfo(alias: "Pixel 8", version: "2.0", fingerprint: "pixel")
    private let files = [
        LocalSend.FileInfo(id: "a", fileName: "a.jpg", size: 10, fileType: "image/jpeg"),
        LocalSend.FileInfo(id: "b", fileName: "b.jpg", size: 20, fileType: "image/jpeg"),
    ]
    private let start = Date(timeIntervalSince1970: 1_000)

    private func makeSession() -> ReceiveSession {
        ReceiveSession(id: "s", sender: sender, senderAddress: "10.0.0.5", files: files, tokens: ["a": "ta", "b": "tb"], now: start)
    }

    @Test func prepareThenUploadEachFileThenDone() {
        var session = makeSession()
        #expect(session.totalSize == 30)
        #expect(session.tokens == ["a": "ta", "b": "tb"])
        let first = session.beginUpload(sessionID: "s", fileID: "a", token: "ta", from: "10.0.0.5", now: start)
        #expect((try? first.get())?.fileName == "a.jpg")
        session.finishUpload(fileID: "a", now: start)
        #expect(session.state == .receiving)
        _ = session.beginUpload(sessionID: "s", fileID: "b", token: "tb", from: "10.0.0.5", now: start)
        session.finishUpload(fileID: "b", now: start)
        #expect(session.state == .finished)
        #expect(session.receivedCount == 2)
    }

    @Test func validatesEveryTokenSessionAndAddress() {
        var session = makeSession()
        func begin(_ sessionID: String?, _ fileID: String?, _ token: String?, _ address: String?) -> ReceiveSession.Rejection? {
            if case let .failure(rejection) = session.beginUpload(sessionID: sessionID, fileID: fileID, token: token, from: address, now: start) {
                return rejection
            }
            return nil
        }
        #expect(begin(nil, "a", "ta", "10.0.0.5") == .missingParameters)
        #expect(begin("s", "a", nil, "10.0.0.5") == .missingParameters)
        #expect(begin("other", "a", "ta", "10.0.0.5") == .forbidden)
        #expect(begin("s", "a", "tb", "10.0.0.5") == .forbidden)
        #expect(begin("s", "zzz", "ta", "10.0.0.5") == .forbidden)
        #expect(begin("s", "a", "ta", "10.0.0.6") == .forbidden)
        #expect(begin("s", "a", "ta", "10.0.0.5") == nil)
        // Already arriving.
        #expect(begin("s", "a", "ta", "10.0.0.5") == .conflict)
        session.finishUpload(fileID: "a", now: start)
        #expect(begin("s", "a", "ta", "10.0.0.5") == .conflict)
    }

    @Test func aFailedUploadCanBeRetried() {
        var session = makeSession()
        _ = session.beginUpload(sessionID: "s", fileID: "a", token: "ta", from: "10.0.0.5", now: start)
        session.failUpload(fileID: "a")
        let retry = session.beginUpload(sessionID: "s", fileID: "a", token: "ta", from: "10.0.0.5", now: start)
        #expect((try? retry.get()) != nil)
    }

    @Test func onlyTheSenderCanCancel() {
        var session = makeSession()
        let byStranger = session.cancel(sessionID: "s", from: "10.0.0.9")
        let wrongSession = session.cancel(sessionID: "x", from: "10.0.0.5")
        let bySender = session.cancel(sessionID: "s", from: "10.0.0.5")
        #expect(!byStranger && !wrongSession && bySender)
        #expect(session.state == .cancelled)
        #expect(!session.isActive)
        if case .success = session.beginUpload(sessionID: "s", fileID: "b", token: "tb", from: "10.0.0.5", now: start) {
            Issue.record("Uploads after cancel must be refused")
        }
    }

    @Test func stalledSessionsExpire() {
        var session = makeSession()
        let early = session.expireIfStalled(now: start.addingTimeInterval(ReceiveSession.stallTimeout - 1))
        session.touch(now: start.addingTimeInterval(100))
        let afterTouch = session.expireIfStalled(now: start.addingTimeInterval(ReceiveSession.stallTimeout + 1))
        let stalled = session.expireIfStalled(now: start.addingTimeInterval(100 + ReceiveSession.stallTimeout))
        #expect(!early && !afterTouch && stalled)
        #expect(session.state == .expired)
        let again = session.expireIfStalled(now: .distantFuture)
        #expect(!again)
    }
}

struct ReceiveRulesTests {
    private func request(_ files: [LocalSend.FileInfo], alias: String = "Pixel 8") -> LocalSend.PrepareUploadRequest {
        LocalSend.PrepareUploadRequest(
            info: LocalSend.DeviceInfo(alias: alias, version: "2.0", fingerprint: "f"),
            files: Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        )
    }

    private let photo = LocalSend.FileInfo(id: "p", fileName: "p.jpg", size: 24_000_000, fileType: "image/jpeg")

    @Test func refusesBusyEmptyMismatchedAndHugeSessions() {
        #expect(ReceiveRules.check(request([photo]), hasActiveSession: false, maxBytes: 10_000_000_000) == .ask)
        #expect(ReceiveRules.check(request([photo]), hasActiveSession: true, maxBytes: 10_000_000_000) == .refuse(409))
        #expect(ReceiveRules.check(request([]), hasActiveSession: false, maxBytes: 10) == .refuse(400))
        #expect(ReceiveRules.check(request([photo]), hasActiveSession: false, maxBytes: 1_000_000) == .refuse(403))
        var mismatched = request([photo])
        mismatched.files = ["other": photo]
        #expect(ReceiveRules.check(mismatched, hasActiveSession: false, maxBytes: .max) == .refuse(400))
        var negative = photo
        negative.size = -1
        #expect(ReceiveRules.check(request([negative]), hasActiveSession: false, maxBytes: .max) == .refuse(400))
    }

    @Test func summaries() {
        let more = [
            photo,
            LocalSend.FileInfo(id: "q", fileName: "q.jpg", size: 0, fileType: "image/jpeg"),
            LocalSend.FileInfo(id: "r", fileName: "r.jpg", size: 0, fileType: "image/jpeg"),
        ]
        #expect(ReceiveRules.summary(of: request(more)) == "Pixel 8 wants to send 3 files (24 MB)")
        let message = LocalSend.FileInfo(id: "m", fileName: "m.txt", size: 2, fileType: "text/plain", preview: "hi")
        #expect(ReceiveRules.summary(of: request([message])) == "Pixel 8 wants to send a message")
        #expect(ReceiveRules.summary(of: request([photo], alias: "")) == "A device wants to send 1 file (24 MB)")
    }

    @Test func defaultLimitIsTenGigabytes() {
        #expect(ReceiveRules.defaultMaxBytes == 10_000_000_000)
        #expect(Preferences(defaults: UserDefaults(suiteName: "ShareLimit-\(UUID().uuidString)") ?? .standard).shareMaxBytes == 10_000_000_000)
    }
}

// MARK: - Browser transfer routes

struct BrowserRouteTests {
    private let token = String(repeating: "a", count: 32)

    @Test func onlyPathsUnderTheTokenAreOurs() {
        #expect(BrowserTransfer.route(path: "/\(token)", token: token) == "/")
        #expect(BrowserTransfer.route(path: "/\(token)/", token: token) == "/")
        #expect(BrowserTransfer.route(path: "/\(token)/items", token: token) == "/items")
        #expect(BrowserTransfer.route(path: "/\(token)x/items", token: token) == nil)
        #expect(BrowserTransfer.route(path: "/", token: token) == nil)
        #expect(BrowserTransfer.route(path: "/api/localsend/v2/info", token: token) == nil)
    }

    @Test func pageLoadsNothingRemote() {
        #expect(!BrowserPage.html.contains("http://"))
        #expect(!BrowserPage.html.contains("https://"))
        #expect(!BrowserPage.html.contains("<script src"))
    }
}

// MARK: - Over a real socket

@MainActor
struct ShareLoopbackTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ShareLoopback-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func serverAnswersAndStreamsChunkedUploads() async throws {
        let server = HTTPServer { request, body in
            guard let data = try? await body.collect(limit: 1 << 20) else { return .status(400) }
            return .json(["path": request.path, "body": String(decoding: data, as: UTF8.self), "q": request.query["q"] ?? ""])
        }
        let port = try await server.start(on: "127.0.0.1")
        defer { server.stop() }
        let endpoint = HTTPClient.Endpoint(host: "127.0.0.1", port: port, usesTLS: false)
        let response = try await HTTPClient.send("POST", to: endpoint, target: "/echo?q=1", body: .data(Data("hi there".utf8)))
        #expect(response.status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: String])
        #expect(json == ["path": "/echo", "body": "hi there", "q": "1"])
    }

    @Test func qrShareLinksStillServeOnlyTheirToken() async throws {
        let server = ShareServer()
        let (session, url) = try await server.share(ShareResource(contentType: "text/plain", body: .data(Data("shared".utf8))), on: "127.0.0.1")
        defer { server.stopAll() }
        let port = try #require(url.port.flatMap { UInt16(exactly: $0) })
        let endpoint = HTTPClient.Endpoint(host: "127.0.0.1", port: port, usesTLS: false)
        let hit = try await HTTPClient.send("GET", to: endpoint, target: "/\(session.token)")
        #expect(hit.status == 200)
        #expect(hit.body == Data("shared".utf8))
        #expect(try await HTTPClient.send("GET", to: endpoint, target: "/nope").status == 404)
        #expect(try await HTTPClient.send("POST", to: endpoint, target: "/\(session.token)").status == 405)
    }

    @Test func localSendRoundTrip() async throws {
        let destination = try temporaryFolder()
        let source = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: source)
        }
        let file = source.appending(path: "../evil name.txt".replacingOccurrences(of: "../", with: ""))
        try Data(repeating: 7, count: 300_000).write(to: file)

        var received: [URL] = []
        var texts: [String] = []
        var asked = 0
        let receiver = LocalSendReceiver(hooks: LocalSendReceiver.Hooks(
            destination: { destination },
            maxBytes: { 10_000_000 },
            ask: { _, _ in
                asked += 1
                return .accept
            },
            trustStore: TrustStore(defaults: UserDefaults(suiteName: "Loopback-\(UUID().uuidString)") ?? .standard),
            onText: { text, _ in texts.append(text) },
            onFilesReceived: { files, _ in received += files },
            onProblem: { _ in }
        ))
        let server = HTTPServer { [receiver] request, body in
            switch request.path {
            case LocalSend.apiPrefix + "/prepare-upload": await receiver.prepareUpload(request, body: body)
            case LocalSend.apiPrefix + "/upload": await receiver.upload(request, body: body)
            case LocalSend.apiPrefix + "/cancel": await receiver.cancel(request)
            default: .status(404)
            }
        }
        let port = try await server.start(on: "127.0.0.1")
        defer { server.stop() }

        let peerInfo = LocalSend.DeviceInfo(alias: "Test Mac", version: "2.2", fingerprint: "peer", port: Int(port), transport: .http)
        let peer = try #require(LocalSendPeer(info: peerInfo, address: "127.0.0.1"))
        let me = LocalSend.DeviceInfo(alias: "Sender", version: "2.2", fingerprint: "me", transport: .http)

        try await LocalSendSender.send([.file(file)], to: peer, as: me) { _ in }
        #expect(asked == 1)
        #expect(received.map(\.lastPathComponent) == ["evil name.txt"])
        #expect(try Data(contentsOf: try #require(received.first)) == Data(repeating: 7, count: 300_000))

        // A message arrives without an upload.
        try await LocalSendSender.send([.text("hello from the test")], to: peer, as: me) { _ in }
        #expect(texts == ["hello from the test"])

        // Nothing is left half-written.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false)).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }

    @Test func declinedSendsReportIt() async throws {
        let receiver = LocalSendReceiver(hooks: LocalSendReceiver.Hooks(
            destination: { FileManager.default.temporaryDirectory },
            maxBytes: { 10 },
            ask: { _, _ in .decline },
            trustStore: TrustStore(defaults: UserDefaults(suiteName: "Decline-\(UUID().uuidString)") ?? .standard),
            onText: { _, _ in }, onFilesReceived: { _, _ in }, onProblem: { _ in }
        ))
        let server = HTTPServer { [receiver] request, body in await receiver.prepareUpload(request, body: body) }
        let port = try await server.start(on: "127.0.0.1")
        defer { server.stop() }
        let peer = try #require(LocalSendPeer(
            info: LocalSend.DeviceInfo(alias: "X", version: "2.2", fingerprint: "x", port: Int(port), transport: .http), address: "127.0.0.1"
        ))
        await #expect(throws: SendError.declined) {
            try await LocalSendSender.send([.text("hi")], to: peer, as: LocalSend.DeviceInfo(alias: "Me", version: "2.2", fingerprint: "me")) { _ in }
        }
    }
}
