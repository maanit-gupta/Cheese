import Foundation
import Testing
@testable import Cheese

struct DropPayloadTests {
    private let file = URL(filePath: "/tmp/Report.pdf")

    @Test func filesWinOverEverythingElse() {
        let payload = DropPayload.resolve(fileURLs: [file], imagePNG: Data([1]), webURL: URL(string: "https://a.com"), string: "x")
        #expect(payload == .files([file]))
    }

    @Test func thenImagesThenLinksThenText() {
        #expect(DropPayload.resolve(fileURLs: [], imagePNG: Data([1]), webURL: URL(string: "https://a.com"), string: "x") == .image(png: Data([1])))
        #expect(DropPayload.resolve(fileURLs: [], imagePNG: nil, webURL: URL(string: "https://a.com/p"), string: "x") == .link(URL(string: "https://a.com/p")!))
        #expect(DropPayload.resolve(fileURLs: [], imagePNG: nil, webURL: nil, string: "hello") == .text("hello"))
    }

    @Test func textThatIsOnlyALinkIsALink() {
        #expect(DropPayload.resolve(fileURLs: [], imagePNG: nil, webURL: nil, string: " https://example.com/x\n") == .link(URL(string: "https://example.com/x")!))
        #expect(DropPayload.resolve(fileURLs: [], imagePNG: nil, webURL: nil, string: "see https://example.com") == .text("see https://example.com"))
        // Only web links count; anything else stays text.
        #expect(DropPayload.resolve(fileURLs: [], imagePNG: nil, webURL: URL(string: "mailto:a@b.c"), string: "mailto:a@b.c") == .text("mailto:a@b.c"))
    }

    @Test func nothingUsable() {
        #expect(DropPayload.resolve(fileURLs: [], imagePNG: Data(), webURL: nil, string: "  \n") == nil)
        #expect(DropPayload.resolve(fileURLs: [URL(string: "https://a.com")!], imagePNG: nil, webURL: nil, string: nil) == nil)
    }
}

struct DropHubPlanTests {
    private let pdf = URL(filePath: "/tmp/Report.pdf")
    private let png = URL(filePath: "/tmp/Shot.png")
    private func size(_ url: URL) -> Int64? { url.pathExtension.isEmpty ? nil : 1_800_000 }

    @Test func offersSharingAndShelfThenTheFilesTools() {
        let tools = ToolApplicability.tools(for: [pdf])
        let plan = DropHubPlan.make(for: .files([pdf]), canShare: true, canShelve: true, tools: tools, size: size)
        #expect(plan.primary == [.shareLink, .addToShelf])
        #expect(plan.sections.map(\.group) == ToolApplicability.grouped(tools).map(\.group))
        #expect(plan.sections.first?.group == .pdf)
        #expect(plan.sections.flatMap(\.tools) == ToolApplicability.grouped(tools).flatMap(\.tools))
        #expect(plan.summary == "Report.pdf · " + ByteCountFormatter.string(fromByteCount: 1_800_000, countStyle: .file))
    }

    @Test func switchedOffFeaturesDisappear() {
        let plan = DropHubPlan.make(for: .files([pdf]), canShare: false, canShelve: true, tools: [], size: size)
        #expect(plan.primary == [.addToShelf])
        #expect(plan.sections.isEmpty)
        #expect(DropHubPlan.make(for: .text("x"), canShare: false, canShelve: false, tools: [], size: size).isEmpty)
    }

    @Test func toolsAreOnlyForFiles() {
        let plan = DropHubPlan.make(for: .text("hello"), canShare: true, canShelve: true, tools: [.mergePDFs], size: size)
        #expect(plan.sections.isEmpty)
    }

    @Test func summaries() {
        #expect(DropHubPlan.summary(of: .files([pdf, png, pdf, png]), size: size) == "4 items dropped")
        #expect(DropHubPlan.summary(of: .files([URL(filePath: "/tmp/Photos/")]), size: size) == "Photos · Folder")
        #expect(DropHubPlan.summary(of: .link(URL(string: "https://www.apple.com/mac")!), size: size) == "www.apple.com")
        #expect(DropHubPlan.summary(of: .text("\n  Meeting notes  \nmore"), size: size) == "Meeting notes")
        #expect(DropHubPlan.summary(of: .image(png: Data(count: 2_000)), size: size).hasPrefix("Image · "))
    }
}

@MainActor
struct DropHubRoutingTests {
    private final class Calls {
        var shared: [DropPayload] = []
        var shelved: [DropPayload] = []
        var tools: [(ToolID, [URL])] = []
    }

    private func model(canShare: Bool = true, canShelve: Bool = true, calls: Calls) -> DropHubModel {
        DropHubModel(services: DropHubServices(
            canShare: { canShare },
            canShelve: { canShelve },
            tools: { ToolApplicability.tools(for: $0) },
            share: { calls.shared.append($0) },
            addToShelf: { calls.shelved.append($0) },
            openTool: { calls.tools.append(($0, $1)) }
        ))
    }

    private let pdfs = [URL(filePath: "/tmp/a.pdf"), URL(filePath: "/tmp/b.pdf")]

    @Test func shareLinkStagesThePayloadAndCloses() {
        let calls = Calls()
        let hub = model(calls: calls)
        var closed = 0
        hub.onFinish = { closed += 1 }
        #expect(hub.load(.files(pdfs)))
        hub.perform(.shareLink)
        #expect(calls.shared == [.files(pdfs)])
        #expect(closed == 1)
        #expect(hub.plan == nil)
    }

    @Test func addToShelfTakesAnyPayload() {
        let calls = Calls()
        let hub = model(calls: calls)
        hub.load(.text("note"))
        hub.perform(.addToShelf)
        #expect(calls.shelved == [.text("note")])
        #expect(calls.shared.isEmpty)
    }

    @Test func toolsOpenWithTheDroppedFiles() {
        let calls = Calls()
        let hub = model(calls: calls)
        hub.load(.files(pdfs))
        hub.perform(.tool(.mergePDFs))
        #expect(calls.tools.map(\.0) == [.mergePDFs])
        #expect(calls.tools.first?.1 == pdfs)
    }

    @Test func onlyOfferedChoicesRun() {
        let calls = Calls()
        let hub = model(canShare: false, calls: calls)
        hub.load(.files(pdfs))
        hub.perform(.shareLink)
        // A tool that doesn't apply to PDFs.
        hub.perform(.tool(.removeBackground))
        #expect(calls.shared.isEmpty)
        #expect(calls.tools.isEmpty)
        #expect(hub.plan != nil)
    }

    @Test func refusesDropsNothingCanTake() {
        let calls = Calls()
        let hub = model(canShare: false, canShelve: false, calls: calls)
        #expect(!hub.load(.text("x")))
        #expect(hub.plan(for: .text("x")) == nil)
        #expect(hub.load(.files(pdfs)))
    }

    @Test func closingWithoutChoosingDoesNothing() {
        let calls = Calls()
        let hub = model(calls: calls)
        hub.load(.text("x"))
        hub.finish()
        hub.perform(.addToShelf)
        #expect(calls.shelved.isEmpty)
    }
}

struct DropHubPlacementTests {
    private let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func hangsCenteredUnderTheIcon() {
        let icon = NSRect(x: 1200, y: 875, width: 30, height: 24)
        #expect(PanelPositions.origin(below: icon, size: NSSize(width: 340, height: 300), in: visible) == NSPoint(x: 1045, y: 569))
    }

    @Test func staysOnScreenNearTheEdge() {
        let icon = NSRect(x: 1420, y: 875, width: 20, height: 24)
        #expect(PanelPositions.origin(below: icon, size: NSSize(width: 340, height: 300), in: visible).x == 1100)
        let tall = PanelPositions.origin(below: icon, size: NSSize(width: 340, height: 2_000), in: visible)
        #expect(tall.y == 0)
    }
}
