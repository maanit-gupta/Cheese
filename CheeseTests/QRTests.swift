import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Cheese

struct QRPayloadPlannerTests {
    private func plan(_ source: QRSource, folders: Set<URL> = []) -> QRPlan {
        QRPayloadPlanner.plan(for: source) { folders.contains($0) }
    }

    @Test func shortTextAndURLsAreEncodedDirectly() {
        #expect(plan(.text("hello")) == .direct("hello"))
        #expect(plan(.text("https://example.com/a?b=c")) == .direct("https://example.com/a?b=c"))
    }

    @Test func limitIsInUTF8Bytes() {
        let fits = String(repeating: "a", count: QRPayloadPlanner.maxDirectBytes)
        #expect(plan(.text(fits)) == .direct(fits))

        let tooLong = fits + "a"
        #expect(plan(.text(tooLong)) == .share(.text(tooLong)))

        // Devanagari is 3 bytes per character, so far fewer characters fit.
        let hindi = String(repeating: "क", count: QRPayloadPlanner.maxDirectBytes / 3 + 1)
        #expect(plan(.text(hindi)) == .share(.text(hindi)))
    }

    @Test func richTextImagesAndFilesAreShared() {
        #expect(plan(.richText("bold")) == .share(.text("bold")))
        let png = TestImages.encoded()
        #expect(plan(.image(png: png)) == .share(.image(png: png)))
    }

    @Test func oneFileIsSentAsIsAndFoldersOrSeveralAreZipped() {
        let file = URL(filePath: "/tmp/a.pdf")
        let other = URL(filePath: "/tmp/b.pdf")
        let folder = URL(filePath: "/tmp/Photos", directoryHint: .isDirectory)
        #expect(plan(.files([file])) == .share(.file(file)))
        #expect(plan(.files([file, other])) == .share(.archive([file, other])))
        #expect(plan(.files([folder]), folders: [folder]) == .share(.archive([folder])))
    }

    @Test func nothingToShowIsEmpty() {
        #expect(plan(.empty) == .empty)
        #expect(plan(.text("  \n ")) == .empty)
        #expect(plan(.files([])) == .empty)
    }
}

@MainActor
struct QRSourceTests {
    @Test func readsTheClipboardLikeHistoryDoes() {
        let pasteboard = FakePasteboard()
        #expect(QRModule.source(from: pasteboard) == .empty)

        pasteboard.setString("hi")
        #expect(QRModule.source(from: pasteboard) == .text("hi"))

        pasteboard.set([[(PasteboardTypeID.plainText, Data("bold".utf8)), (PasteboardTypeID.rtf, Data("{\\rtf1 bold}".utf8))]])
        #expect(QRModule.source(from: pasteboard) == .richText("bold"))

        let file = URL(filePath: "/tmp/report.pdf")
        pasteboard.set([[(PasteboardTypeID.fileURL, file.dataRepresentation)]])
        #expect(QRModule.source(from: pasteboard) == .files([file]))
    }

    @Test func imagesBecomePNG() {
        let pasteboard = FakePasteboard()
        pasteboard.set([[(PasteboardTypeID.tiff, TestImages.encoded(type: .tiff))]])
        guard case let .image(png) = QRModule.source(from: pasteboard) else {
            Issue.record("Expected an image")
            return
        }
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func secretsAreNeverShown() {
        let pasteboard = FakePasteboard()
        pasteboard.set([[(PasteboardTypeID.plainText, Data("hunter2".utf8)), (PasteboardTypeID.concealed, Data())]])
        #expect(QRModule.source(from: pasteboard) == .empty)
    }
}

struct QRGeneratorTests {
    @Test func makesASharpCodeAtLeastTheMinimumSize() throws {
        let image = try #require(QRGenerator.image(for: "https://example.com", minimumPixels: 640))
        #expect(image.width >= 640)
        #expect(image.width == image.height)
    }

    @Test func theLargestDirectPayloadStillFits() {
        let text = String(repeating: "a", count: QRPayloadPlanner.maxDirectBytes)
        #expect(QRGenerator.image(for: text, minimumPixels: 100) != nil)
    }
}

struct ShareRulesTests {
    private struct SequenceGenerator: RandomNumberGenerator {
        var values: [UInt64]
        mutating func next() -> UInt64 { values.removeFirst() }
    }

    private func session(_ token: String, expiresAt: Date) -> ShareSession {
        ShareSession(token: token, resource: ShareResource(contentType: "text/plain", body: .data(Data())), expiresAt: expiresAt)
    }

    @Test func tokensAre128BitHex() {
        var generator = SequenceGenerator(values: [0x0123_4567_89ab_cdef, 0xf])
        let token = ShareRules.makeToken(using: &generator)
        #expect(token == "0123456789abcdef000000000000000f")
        #expect(ShareRules.makeToken().count == 32)
        #expect(ShareRules.makeToken() != ShareRules.makeToken())
    }

    @Test func onlyTheExactTokenPathMatches() {
        let token = "0123456789abcdef0123456789abcdef"
        #expect(ShareRules.token(fromPath: "/" + token) == token)
        #expect(ShareRules.token(fromPath: "/" + token + "/") == nil)
        #expect(ShareRules.token(fromPath: "/" + token.uppercased()) == nil)
        #expect(ShareRules.token(fromPath: "/" + token.dropLast()) == nil)
        #expect(ShareRules.token(fromPath: "/../" + token) == nil)
        #expect(ShareRules.token(fromPath: "/") == nil)
        #expect(ShareRules.token(fromPath: "/" + token + "?x=1") == nil)
    }

    @Test func expiredOrUnknownLinksDontResolve() {
        let now = Date(timeIntervalSince1970: 1_000)
        let live = session("0123456789abcdef0123456789abcdef", expiresAt: now.addingTimeInterval(60))
        let expired = session("fedcba9876543210fedcba9876543210", expiresAt: now)
        let sessions = [live, expired]

        #expect(ShareRules.session(forPath: "/" + live.token, in: sessions, now: now)?.token == live.token)
        #expect(ShareRules.session(forPath: "/" + expired.token, in: sessions, now: now) == nil)
        #expect(ShareRules.session(forPath: "/" + live.token, in: sessions, now: now.addingTimeInterval(60)) == nil)
        #expect(ShareRules.session(forPath: "/abc", in: sessions, now: now) == nil)
    }

    @Test func linksLastTenMinutes() {
        #expect(ShareRules.lifetime == 600)
    }
}

struct HTTPMessageTests {
    private let token = "0123456789abcdef0123456789abcdef"

    private var sessions: [ShareSession] {
        [ShareSession(token: token, resource: ShareResource(contentType: "text/plain", body: .data(Data())), expiresAt: .distantFuture)]
    }

    @Test func parsesTheRequestLine() {
        let request = Data("GET /\(token) HTTP/1.1\r\nHost: 192.168.1.2\r\n\r\n".utf8)
        #expect(HTTPMessage.hasCompleteHead(request))
        #expect(HTTPMessage.parseHead(request) == .init(method: "GET", path: "/\(token)"))
    }

    @Test func incompleteAndMalformedRequests() {
        #expect(!HTTPMessage.hasCompleteHead(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)))
        #expect(HTTPMessage.parseHead(Data("GET /\r\n\r\n".utf8)) == nil)
        #expect(HTTPMessage.parseHead(Data("GET  / HTTP/1.1\r\n\r\n".utf8)) == nil)
        #expect(HTTPMessage.parseHead(Data("GET http://x/ HTTP/1.1\r\n\r\n".utf8)) == nil)
        #expect(HTTPMessage.parseHead(Data([0xff, 0xfe, 0x0d, 0x0a])) == nil)
    }

    @Test func routesGETForLiveTokensOnly() {
        #expect(HTTPMessage.route(.init(method: "GET", path: "/\(token)"), sessions: sessions, now: .now) == .serve(token: token, .page))
        #expect(HTTPMessage.route(.init(method: "GET", path: "/\(token)/"), sessions: sessions, now: .now) == .serve(token: token, .page))
        #expect(HTTPMessage.route(.init(method: "GET", path: "/\(token)/state"), sessions: sessions, now: .now) == .serve(token: token, .state))
        #expect(HTTPMessage.route(.init(method: "GET", path: "/\(token)/download"), sessions: sessions, now: .now) == .serve(token: token, .download))
        #expect(HTTPMessage.route(.init(method: "GET", path: "/\(token)/other"), sessions: sessions, now: .now) == .status(404))
        #expect(HTTPMessage.route(.init(method: "GET", path: "/\(token)/download/x"), sessions: sessions, now: .now) == .status(404))
        #expect(HTTPMessage.route(.init(method: "GET", path: "/\(token)//download"), sessions: sessions, now: .now) == .status(404))
        #expect(HTTPMessage.route(.init(method: "GET", path: "/"), sessions: sessions, now: .now) == .status(404))
        #expect(HTTPMessage.route(.init(method: "GET", path: "/favicon.ico"), sessions: sessions, now: .now) == .status(404))
        #expect(HTTPMessage.route(.init(method: "POST", path: "/\(token)"), sessions: sessions, now: .now) == .status(405))
        #expect(HTTPMessage.route(.init(method: "HEAD", path: "/\(token)"), sessions: sessions, now: .now) == .status(405))
        #expect(HTTPMessage.route(nil, sessions: sessions, now: .now) == .status(400))
        #expect(HTTPMessage.route(.init(method: "GET", path: "/\(token)"), sessions: [], now: .now) == .status(404))
    }

    @Test func responseHeadFormat() {
        let head = String(decoding: HTTPMessage.responseHead(status: 404, headers: [("Content-Length", "0")]), as: UTF8.self)
        #expect(head == "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
    }

    @Test func attachmentNamesAreQuotedSafely() {
        #expect(HTTPMessage.contentDisposition(attachmentName: "report.pdf") == "attachment; filename=\"report.pdf\"; filename*=UTF-8''report.pdf")
        let tricky = HTTPMessage.contentDisposition(attachmentName: "a \"b\"\r\nX: y.txt")
        #expect(!tricky.contains("\r") && !tricky.contains("\n"))
        #expect(tricky.hasPrefix("attachment; filename=\"a _b___X: y.txt\""))
        #expect(HTTPMessage.contentDisposition(attachmentName: "नमस्ते.txt").contains("filename*=UTF-8''%E0%A4%A8"))
    }
}

struct LANAddressTests {
    private func address(_ interface: String, _ address: String, up: Bool = true, loopback: Bool = false) -> InterfaceAddress {
        InterfaceAddress(interface: interface, address: address, isUp: up, isLoopback: loopback)
    }

    @Test func prefersWiFiOverOtherInterfaces() {
        let addresses = [
            address("lo0", "127.0.0.1", loopback: true),
            address("utun3", "10.8.0.2"),
            address("en5", "192.168.0.9"),
            address("en0", "192.168.1.20"),
        ]
        #expect(LANAddress.best(from: addresses) == "192.168.1.20")
    }

    @Test func fallsBackToOtherEthernet() {
        #expect(LANAddress.best(from: [address("bridge0", "192.168.2.1"), address("en7", "10.0.0.5")]) == "10.0.0.5")
    }

    @Test func noLocalNetwork() {
        #expect(LANAddress.best(from: []) == nil)
        #expect(LANAddress.best(from: [address("lo0", "127.0.0.1", loopback: true)]) == nil)
        #expect(LANAddress.best(from: [address("en0", "169.254.3.4")]) == nil)
        #expect(LANAddress.best(from: [address("en0", "192.168.1.20", up: false)]) == nil)
        #expect(LANAddress.best(from: [address("en0", "17.5.6.7")]) == nil)
    }

    @Test(arguments: [
        ("10.1.2.3", true), ("172.16.0.1", true), ("172.31.255.255", true), ("192.168.0.1", true),
        ("172.32.0.1", false), ("172.15.0.1", false), ("169.254.1.1", false), ("8.8.8.8", false), ("nonsense", false),
    ])
    func privateRanges(_ address: String, _ isPrivate: Bool) {
        #expect(LANAddress.isPrivateIPv4(address) == isPrivate)
    }
}

/// The real server on loopback: serves only the live token, and stops with the last share.
@MainActor
struct ShareServerTests {
    private func get(_ url: URL, method: String = "GET") async throws -> (status: Int, body: Data, headers: [AnyHashable: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let http = response as? HTTPURLResponse
        return (http?.statusCode ?? 0, data, http?.allHeaderFields ?? [:])
    }

    @Test func servesTheShareAndNothingElse() async throws {
        let server = ShareServer()
        server.deviceName = { "Test Mac" }
        defer { server.stopAll() }
        let resource = try await QRPanelController.resource(for: .text("hello <b>"))
        let (session, url) = try await server.share(resource, on: "127.0.0.1")

        // The link opens the Share page, with the text on it.
        let ok = try await get(url)
        #expect(ok.status == 200)
        let page = String(decoding: ok.body, as: UTF8.self)
        #expect(page.contains("Connected to <b>Test Mac</b>"))
        #expect(page.contains("<div class=\"txt\">hello &lt;b&gt;</div>"))
        #expect(page.contains("data-base=\"/\(session.token)/\""))
        #expect(!page.contains("id=\"files\""))

        let state = try await get(url.appending(path: "state"))
        let decoded = try JSONDecoder().decode(BrowserSharePageRenderer.State.self, from: state.body)
        #expect((1...600).contains(decoded.expiresIn ?? 0))
        #expect(decoded.html.contains("Copy Text"))

        var other = URLComponents(url: url, resolvingAgainstBaseURL: false)
        other?.path = "/nope"
        let missing = try await get(try #require(other?.url))
        #expect(missing.status == 404)

        #expect(try await get(url, method: "POST").status == 405)

        server.stop(session.token)
        #expect(!server.hasActiveShares)
        var refused = false
        do {
            _ = try await get(url)
        } catch {
            refused = true
        }
        #expect(refused)
    }

    @Test func filesAreDownloadsAndTempFilesAreDeleted() async throws {
        let folder = makeTemporaryDirectory()
        let file = folder.appending(path: "notes.txt")
        let contents = Data(repeating: 0x61, count: 3 << 20)
        try contents.write(to: file)

        let server = ShareServer()
        defer { server.stopAll() }
        var ended: [String] = []
        server.onShareEnded = { ended.append($0) }
        let resource = ShareResource(contentType: "text/plain", body: .file(file), attachmentName: "notes.txt", temporaryFiles: [folder])
        let (session, url) = try await server.share(resource, on: "127.0.0.1")

        let response = try await get(url.appending(path: "download"))
        #expect(response.status == 200)
        #expect(response.body == contents)
        #expect((response.headers["Content-Disposition"] as? String)?.hasPrefix("attachment; filename=\"notes.txt\"") == true)

        server.stop(session.token)
        #expect(ended == [session.token])
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    @Test func zipsFoldersForSharing() async throws {
        let folder = makeTemporaryDirectory().appending(path: "Photos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "a.txt"))

        let archive = try await ShareArchiver.archive([folder])
        defer { try? FileManager.default.removeItem(at: archive.temporaryFolder) }
        #expect(archive.zip.lastPathComponent == "Photos.zip")
        let data = try Data(contentsOf: archive.zip)
        #expect(data.starts(with: [0x50, 0x4B, 0x03, 0x04]))
    }

    @Test func linkPagesListWhatsShared() async throws {
        let folder = makeTemporaryDirectory()
        let a = folder.appending(path: "a.pdf")
        let b = folder.appending(path: "b.txt")
        try Data(count: 2_400).write(to: a)
        try Data(count: 10).write(to: b)
        defer { try? FileManager.default.removeItem(at: folder) }

        let one = try await QRPanelController.resource(for: .file(a))
        #expect(one.items == [.file(.init(name: "a.pdf", size: 2_400, mimeType: "application/pdf", href: "download"))])
        #expect(!one.isArchive)

        let image = try await QRPanelController.resource(for: .image(png: Data(count: 50)))
        #expect(image.items == [.file(.init(name: "Image.png", size: 50, mimeType: "image/png", href: "download"))])

        let several = try await QRPanelController.resource(for: .archive([a, b]))
        defer { several.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(several.isArchive)
        #expect(several.items.count == 2)
        let server = ShareServer()
        server.deviceName = { "Mac" }
        let session = ShareSession(token: ShareRules.makeToken(), resource: several, expiresAt: .now.addingTimeInterval(90))
        let html = BrowserSharePageRenderer.html(server.page(for: session))
        #expect(html.contains("Download All (.zip)"))
        #expect(html.contains("href=\"/\(session.token)/download\" download>"))
        #expect(html.contains("data-expires=\"90\""))
    }
}
