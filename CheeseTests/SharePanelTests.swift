import Foundation
import Testing
@testable import Cheese

struct SharePanelTextTests {
    @Test func shortLinksKeepHostPortAndTheTokensStart() {
        let url = URL(string: "http://192.168.1.42:54812/3f9a2c0011223344556677889900aabb/")!
        #expect(ShareLinkText.short(url) == "192.168.1.42:54812/3f9a2c…")
        #expect(ShareLinkText.short(URL(string: "http://10.0.0.2:80/abc")!) == "10.0.0.2:80/abc")
    }

    @Test func statusCountsDownOnlyOnceThereIsAnEnd() {
        let now = Date.now
        #expect(ShareLinkText.status(expiresAt: now.addingTimeInterval(598), now: now) == "Same Wi-Fi · Expires in 9:58")
        #expect(ShareLinkText.status(expiresAt: now.addingTimeInterval(-3), now: now) == "Same Wi-Fi · Expires in 0:00")
        #expect(ShareLinkText.status(expiresAt: nil, now: now) == "Same Wi-Fi · Live while Share is open")
    }

    @Test func stagedSummaries() {
        #expect(SharePanelModel.summary(of: []) == nil)
        #expect(SharePanelModel.summary(of: [.text("Meet at six\nbring cake")]) == "“Meet at six”")
        #expect(SharePanelModel.summary(of: [.text("a"), .text("b")]) == "2 items")
    }

    @Test func receivedSummaries() {
        let photo = ShareService.ReceivedFile(url: URL(filePath: "/tmp/IMG_2041.HEIC"), from: "your phone", size: 2_400_000)
        let note = ShareService.ReceivedFile(url: URL(filePath: "/tmp/Notes.pdf"), from: "Pixel 8", size: 600_000)
        #expect(SharePanelModel.receivedSummary(of: []) == nil)
        #expect(SharePanelModel.receivedSummary(of: [photo]) == "IMG_2041.HEIC · 2.4 MB")
        #expect(SharePanelModel.receivedSummary(of: [photo, note]) == "2 files · 3 MB")
    }

    @Test func phases() {
        let link = URL(string: "http://10.0.0.2:5000/abc/")!
        #expect(SharePanelModel.phase(stoppedByUser: false, listening: .stopped, link: nil) == .starting)
        #expect(SharePanelModel.phase(stoppedByUser: false, listening: .listening(address: "10.0.0.2", port: 1), link: link) == .live(link))
        #expect(SharePanelModel.phase(stoppedByUser: false, listening: .listening(address: "10.0.0.2", port: 1), link: nil) == .starting)
        #expect(SharePanelModel.phase(stoppedByUser: true, listening: .listening(address: "10.0.0.2", port: 1), link: link) == .stopped)
        #expect(SharePanelModel.phase(stoppedByUser: false, listening: .unavailable("No Wi-Fi"), link: nil) == .unavailable("No Wi-Fi"))
    }

    @Test(arguments: [(40, CGFloat(180)), (150, 180), (151, 240), (800, 240), (2_000, 320)])
    func denseCodesDrawBigger(_ bytes: Int, _ side: CGFloat) {
        #expect(QRPanelController.codeSide(forDirectBytes: bytes) == side)
    }
}

/// The Share panel against a real `ShareService` on loopback: empty → staged files → clipboard
/// staged → stop sharing → share again.
@MainActor
struct SharePanelStateTests {
    @MainActor private final class Clipboard {
        var items: [OutgoingItem] = []
    }

    private func makeModel(clipboard: @escaping @MainActor () -> [OutgoingItem] = { [] }) -> SharePanelModel {
        var hooks = ShareService.Hooks(ask: { _, _ in .decline }, receivedText: { _, _ in }, setListening: { _ in })
        hooks.address = { "127.0.0.1" }
        hooks.identity = { nil }
        return SharePanelModel(service: ShareService(hooks: hooks), clipboardItems: clipboard)
    }

    private func waitUntil(_ condition: () -> Bool, within seconds: Double = 5) async {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition(), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func pageState(_ link: URL) async throws -> BrowserSharePageRenderer.State {
        let endpoint = HTTPClient.Endpoint(host: "127.0.0.1", port: UInt16(try #require(link.port)), usesTLS: false)
        let response = try await HTTPClient.send("GET", to: endpoint, target: link.path(percentEncoded: true) + "state")
        return try JSONDecoder().decode(BrowserSharePageRenderer.State.self, from: response.body)
    }

    @Test func fromEmptyToStagedToStopped() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SharePanel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appending(path: "Report.pdf")
        try Data(count: 1_800).write(to: report)

        let clipboard = Clipboard()
        let model = makeModel { clipboard.items }
        defer { model.service.stop() }

        // Empty: the link goes live with nothing staged.
        model.opened()
        await waitUntil { if case .live = model.phase { true } else { false } }
        guard case let .live(link) = model.phase else {
            Issue.record("Share never went live: \(model.phase)")
            return
        }
        #expect(model.service.staged.isEmpty)
        #expect(SharePanelModel.summary(of: model.service.staged) == nil)
        #expect(try await pageState(link).html.contains("Nothing from your Mac yet"))

        // Staged files: on the strip and on the phone's page.
        model.pickFiles = { [report] }
        model.addFiles()
        model.addFiles()
        #expect(model.service.staged.map(\.name) == ["Report.pdf"])
        #expect(SharePanelModel.summary(of: model.service.staged)?.hasPrefix("Report.pdf · ") == true)
        #expect(try await pageState(link).html.contains("Report.pdf"))

        // Share Clipboard: an empty clipboard changes nothing; then its text joins the files.
        #expect(!model.shareClipboard())
        clipboard.items = [.text("from the clipboard")]
        #expect(model.shareClipboard())
        #expect(model.service.staged.count == 2)
        #expect(SharePanelModel.summary(of: model.service.staged)?.hasPrefix("2 items · ") == true)
        let state = try await pageState(link)
        #expect(state.html.contains("from the clipboard"))
        #expect(state.html.contains("Download File"))

        // Dropping files on the panel (not on a device) stages them too.
        let notes = folder.appending(path: "notes.txt")
        try Data("n".utf8).write(to: notes)
        model.dragMoved(to: CGPoint(x: 10, y: 10))
        #expect(model.isDropTargeted)
        #expect(model.drop([notes]))
        #expect(!model.isDropTargeted)
        #expect(model.service.staged.count == 3)

        // Stop: the link dies and the strip empties.
        model.stop()
        #expect(model.phase == .stopped)
        #expect(model.service.staged.isEmpty)
        #expect(model.service.browserURL == nil)
        let endpoint = HTTPClient.Endpoint(host: "127.0.0.1", port: UInt16(try #require(link.port)), usesTLS: false)
        #expect((try? await HTTPClient.send("GET", to: endpoint, target: link.path(percentEncoded: true), timeout: .seconds(2))) == nil)

        // Share Again: a fresh link.
        model.startAgain()
        await waitUntil { if case .live = model.phase { true } else { false } }
        guard case let .live(again) = model.phase else {
            Issue.record("Share didn't start again: \(model.phase)")
            return
        }
        #expect(again.path() != link.path())
    }

    @Test func clearEmptiesTheStripAndThePage() async throws {
        let model = makeModel { [.text("one"), .text("two")] }
        defer { model.service.stop() }
        model.opened()
        await waitUntil { if case .live = model.phase { true } else { false } }
        guard case let .live(link) = model.phase else { return }
        model.shareClipboard()
        #expect(model.service.staged.count == 2)
        model.service.unstage(model.service.staged[0].id)
        #expect(model.service.staged.map(\.name) == ["two"])
        model.service.clearStaged()
        #expect(model.service.staged.isEmpty)
        #expect(try await pageState(link).html.contains("Nothing from your Mac yet"))
    }

    @Test func receivedFilesListNewestFirstAndOutliveStop() {
        let model = makeModel()
        let service = model.service
        let first = URL(filePath: "/tmp/a.jpg"), second = URL(filePath: "/tmp/b.pdf"), third = URL(filePath: "/tmp/c.txt")
        service.record([first, second], from: "your phone")
        service.record([third], from: "Pixel 8")
        #expect(service.received.map(\.url) == [third, second, first])
        #expect(service.received.map(\.from) == ["Pixel 8", "your phone", "your phone"])

        // Only the last 50 are kept.
        service.record((0..<60).map { URL(filePath: "/tmp/\($0).png") }, from: "your phone")
        #expect(service.received.count == 50)
        #expect(service.received.first?.url.lastPathComponent == "59.png")

        // Stopping the link keeps them a click away; Clear List empties it.
        model.stop()
        #expect(service.received.count == 50)
        service.clearReceived()
        #expect(service.received.isEmpty)
    }
}
