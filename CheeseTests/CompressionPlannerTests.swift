import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Cheese

struct CompressionPlannerTests {
    /// Sizes that shrink steadily along the ladder: 10 MB at the gentlest step, 1 MB at the strongest.
    private static func steadySize(_ parameters: CompressionParameters) -> Int {
        let index = CompressionPlanner.ladder.firstIndex(of: parameters) ?? 0
        let steps = CompressionPlanner.ladder.count - 1
        return 10_000_000 - index * 9_000_000 / steps
    }

    @Test func ladderRunsFromGentleToStrong() throws {
        let ladder = CompressionPlanner.ladder
        let first = try #require(ladder.first)
        let last = try #require(ladder.last)
        #expect(first == CompressionParameters(dpi: 200, quality: 0.8))
        #expect(last == CompressionParameters(dpi: 72, quality: 0.4))
        #expect(zip(ladder, ladder.dropFirst()).allSatisfy { $0.dpi >= $1.dpi && $0.quality >= $1.quality })
    }

    @Test func stageOneIsEnoughWhenItReachesTheTarget() async throws {
        let outcome = try await CompressionPlanner.plan(target: 5_000_000, stageOneSize: 4_000_000) { _ in
            Issue.record("Shouldn't re-render when stage one is small enough")
            return 0
        }
        #expect(outcome == .reached(size: 4_000_000, parameters: nil))
    }

    @Test func findsTheGentlestStepUnderTheTarget() async throws {
        let tried = Mutex<[CompressionParameters]>([])
        let outcome = try await CompressionPlanner.plan(target: 6_000_000, stageOneSize: 12_000_000) { parameters in
            tried.withLock { $0.append(parameters) }
            return Self.steadySize(parameters)
        }
        guard case let .reached(size, parameters?) = outcome else {
            Issue.record("Expected to reach the target, got \(outcome)")
            return
        }
        #expect(size <= 6_000_000)
        // The step before the chosen one must be over the target, or the search wasn't the gentlest.
        let index = try #require(CompressionPlanner.ladder.firstIndex(of: parameters))
        #expect(index > 0)
        #expect(Self.steadySize(CompressionPlanner.ladder[index - 1]) > 6_000_000)
        // A binary search: far fewer tries than the ladder has steps, and none repeated.
        let attempts = tried.withLock { $0 }
        #expect(attempts.count <= 5)
        #expect(Set(attempts.map(\.dpi)).count == attempts.count)
    }

    @Test func reportsTheSmallestWhenTheTargetIsOutOfReach() async throws {
        let outcome = try await CompressionPlanner.plan(target: 500_000, stageOneSize: 12_000_000, sizeFor: Self.steadySize)
        #expect(outcome == .floor(smallest: 1_000_000, parameters: CompressionPlanner.ladder.last))
    }

    @Test func stageOneCanBeTheSmallestEvenAtTheFloor() async throws {
        let outcome = try await CompressionPlanner.plan(target: 100, stageOneSize: 900) { _ in 5_000 }
        #expect(outcome == .floor(smallest: 900, parameters: nil))
    }

    @Test func messagesExplainTheResult() {
        #expect(CompressionPlanner.unreachableMessage(target: 2_000_000, smallest: 3_400_000) == "Couldn't reach 2 MB — smallest possible is 3.4 MB")
    }

    @Test func coverageAddsImageAreaWithinThePage() {
        let page = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(PDFImageInspector.coverage(of: [CGRect(x: 0, y: 0, width: 100, height: 60)], on: page) == 0.6)
        #expect(PDFImageInspector.coverage(of: [CGRect(x: 50, y: 50, width: 100, height: 100)], on: page) == 0.25)
        #expect(PDFImageInspector.coverage(of: [page, page], on: page) == 1)
        #expect(PDFImageInspector.coverage(of: [], on: page) == 0)
    }
}

@MainActor
struct PDFCompressorTests {
    @Test func findsImageDominantPagesOnly() throws {
        let url = TestPDFs.writeMixed(to: makeTemporaryDirectory().appending(path: "Mixed.pdf"), imagePixels: 64)
        let document = try #require(CGPDFDocument(url as CFURL))
        let imagePage = try #require(document.page(at: 1))
        let textPage = try #require(document.page(at: 2))
        let rects = PDFImageInspector.imageRects(on: imagePage)
        #expect(rects.count == 1)
        #expect(abs((rects.first?.width ?? 0) - 612) < 1)
        #expect(PDFImageInspector.isImageDominant(imagePage))
        #expect(!PDFImageInspector.isImageDominant(textPage))
    }

    @Test func compressesImagePagesAndKeepsTextPagesVector() async throws {
        let input = TestPDFs.writeMixed(to: makeTemporaryDirectory().appending(path: "Scan.pdf"))
        let before = ImageFiles.fileSize(input)
        let target = Int(before / 10)
        let report = try await runJob(CompressTool().work(inputs: [input], options: .init(targetMB: Double(target) / 1_000_000)))
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Scan (compressed).pdf")
        #expect(ImageFiles.fileSize(output) < before)
        #expect(TestPDFs.pageTexts(output) == ["", "Plain text page"])
        #expect(report.notes.count == 1)
    }

    @Test func keepsTheOriginalWhenNothingIsSmaller() async throws {
        let input = TestPDFs.write(pages: 1, to: makeTemporaryDirectory().appending(path: "Tiny.pdf"))
        let report = try await runJob(CompressTool().work(inputs: [input], options: .init(targetMB: 0.000_1)))
        if report.outputs.isEmpty {
            #expect(report.notes == ["Tiny.pdf can't be made smaller; kept the original."])
        } else {
            // PDFKit managed to shave a few bytes; then it's the floor message.
            #expect(report.notes.first?.contains("Couldn't reach") == true)
        }
    }
}
