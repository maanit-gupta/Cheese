import Foundation
import PDFKit
import Testing
@testable import Cheese

struct PageRangeParserTests {
    @Test func parsesSinglesRangesAndOpenEnds() throws {
        #expect(try PageRangeParser.parse("1-3, 5, 8-", pageCount: 10) == [1...3, 5...5, 8...10])
        #expect(try PageRangeParser.parse("-2", pageCount: 10) == [1...2])
        #expect(try PageRangeParser.parse(" 2 – 4 ;6 ", pageCount: 10) == [2...4, 6...6])
        #expect(try PageRangeParser.parse("4 - 4", pageCount: 4) == [4...4])
    }

    @Test func reportsClearErrors() {
        #expect(throws: PageRangeError.empty) { try PageRangeParser.parse(" , ", pageCount: 3) }
        #expect(throws: PageRangeError.invalidToken("x")) { try PageRangeParser.parse("1, x", pageCount: 3) }
        #expect(throws: PageRangeError.invalidToken("1-2-3")) { try PageRangeParser.parse("1-2-3", pageCount: 3) }
        #expect(throws: PageRangeError.invalidToken("-")) { try PageRangeParser.parse("-", pageCount: 3) }
        #expect(throws: PageRangeError.pageZero) { try PageRangeParser.parse("0-2", pageCount: 3) }
        #expect(throws: PageRangeError.outOfRange(12, pageCount: 10)) { try PageRangeParser.parse("8-12", pageCount: 10) }
        #expect(throws: PageRangeError.reversed(5, 3)) { try PageRangeParser.parse("5-3", pageCount: 10) }
        #expect(PageRangeError.outOfRange(12, pageCount: 10).errorDescription == "There's no page 12: the PDF has 10 pages")
    }

    @Test func formatsCompactLabels() {
        #expect(PageRangeFormatter.label([1, 2, 3, 5]) == "pages 1-3, 5")
        #expect(PageRangeFormatter.label([4]) == "page 4")
        #expect(PageRangeFormatter.compact([3, 1, 2]) == "3, 1-2")
    }
}

struct SplitPlannerTests {
    @Test func rangesBecomeOnePartEach() throws {
        let parts = try SplitPlanner.parts(mode: .ranges, ranges: "1-3, 5", everyN: 1, pageCount: 6)
        #expect(parts == [SplitPart(pages: [1, 2, 3], label: "pages 1-3"), SplitPart(pages: [5], label: "page 5")])
    }

    @Test func everyNKeepsTheShortRemainder() throws {
        let parts = try SplitPlanner.parts(mode: .everyN, ranges: "", everyN: 3, pageCount: 7)
        #expect(parts.map(\.pages) == [[1, 2, 3], [4, 5, 6], [7]])
    }

    @Test func eachPageAndEmptyDocuments() throws {
        #expect(try SplitPlanner.parts(mode: .eachPage, ranges: "", everyN: 1, pageCount: 3).map(\.pages) == [[1], [2], [3]])
        #expect(try SplitPlanner.parts(mode: .eachPage, ranges: "", everyN: 1, pageCount: 0).isEmpty)
        #expect(try SplitPlanner.parts(mode: .everyN, ranges: "", everyN: 0, pageCount: 2).map(\.pages) == [[1], [2]])
    }

    @Test func badRangesThrow() {
        #expect(throws: PageRangeError.outOfRange(9, pageCount: 4)) {
            try SplitPlanner.parts(mode: .ranges, ranges: "9", everyN: 1, pageCount: 4)
        }
    }
}

struct PageEditingTests {
    private let pages = PageEditing.initial(pageCount: 5)

    @Test func rotatesOnlySelectedPagesAndWraps() {
        let turned = PageEditing.rotate(pages, ids: [1], by: -90)
        #expect(turned[1].rotation == 270)
        #expect(turned[0].rotation == 0)
        #expect(PageEditing.rotate(turned, ids: [1], by: 90)[1].rotation == 0)
    }

    @Test func movesSelectionAsABlockBeforeTheTarget() {
        let moved = PageEditing.move(pages, ids: [3, 1], before: 0)
        #expect(moved.map(\.id) == [1, 3, 0, 2, 4])
        #expect(PageEditing.move(pages, ids: [0], before: nil).map(\.id) == [1, 2, 3, 4, 0])
        #expect(PageEditing.move(pages, ids: [2, 3], before: 3) == pages)
    }

    @Test func deletesAndSelectsRanges() {
        #expect(PageEditing.delete(pages, ids: [0, 4]).map(\.source) == [1, 2, 3])
        #expect(PageEditing.range(from: 3, to: 1, in: pages) == [1, 2, 3])
        #expect(PageEditing.range(from: 9, to: 1, in: pages) == [1])
    }

    @Test func historyUndoesAndRedoesAndSkipsNoOps() {
        var history = UndoHistory(pages)
        history.apply(pages)
        #expect(!history.canUndo)
        history.apply(PageEditing.delete(pages, ids: [0]))
        history.apply(PageEditing.delete(history.current, ids: [1]))
        #expect(history.current.count == 3)
        history.undo()
        #expect(history.current.count == 4)
        history.redo()
        #expect(history.current.count == 3)
        history.undo()
        history.apply(PageEditing.rotate(history.current, ids: [2], by: 90))
        #expect(!history.canRedo)
    }
}

@MainActor
struct PageEditorModelTests {
    @Test func clickModifiersBuildTheSelection() {
        let model = PageEditorModel(url: URL(filePath: "/tmp/x.pdf"), pageCount: 6)
        model.click(1, modifiers: [])
        model.click(4, modifiers: .shift)
        #expect(model.selection == [1, 2, 3, 4])
        model.click(2, modifiers: .command)
        #expect(model.selection == [1, 3, 4])
        model.click(5, modifiers: [])
        #expect(model.selection == [5])
    }

    @Test func cannotDeleteEveryPage() {
        let model = PageEditorModel(url: URL(filePath: "/tmp/x.pdf"), pageCount: 2)
        model.selectAll()
        #expect(!model.canDelete)
        model.deleteSelected()
        #expect(model.pages.count == 2)
        #expect(!model.isDirty)
    }

    @Test func savesReorderedRotatedPagesAsAnEditedCopy() async throws {
        let folder = makeTemporaryDirectory()
        let input = TestPDFs.write(pages: 3, to: folder.appending(path: "Report.pdf"))
        let model = PageEditorModel(url: input, pageCount: 3)
        model.click(2, modifiers: [])
        model.drop(2, before: 0)
        model.rotateSelected(by: 90)
        let report = try await runJob(model.saveWork())
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Report (edited).pdf")
        #expect(TestPDFs.pageTexts(output) == ["Page 3", "Page 1", "Page 2"])
        #expect(PDFDocument(url: output)?.page(at: 0)?.rotation == 90)

        model.click(1, modifiers: [])
        let extracted = try await runJob(try #require(model.extractWork()))
        #expect(extracted.outputs.first?.lastPathComponent == "Report (page 2).pdf")
        #expect(TestPDFs.pageTexts(try #require(extracted.outputs.first)) == ["Page 2"])
    }
}

@MainActor
struct MergeAndSplitTests {
    @Test func mergeKeepsOrderAndAddsABookmarkPerSource() async throws {
        let folder = makeTemporaryDirectory()
        let a = TestPDFs.write(pages: 2, to: folder.appending(path: "Report.pdf"), label: "A")
        let b = TestPDFs.write(pages: 1, to: folder.appending(path: "Appendix.pdf"), label: "B")
        let report = try await runJob(MergeTool().work(inputs: [b, a], options: NoOptions()))
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Appendix (merged).pdf")
        #expect(TestPDFs.pageTexts(output) == ["B 1", "A 1", "A 2"])
        let document = try #require(PDFDocument(url: output))
        let root = try #require(document.outlineRoot)
        #expect(root.numberOfChildren == 2)
        #expect(root.child(at: 1)?.label == "Report")
        let target = try #require(root.child(at: 1)?.destination?.page)
        #expect(document.index(for: target) == 1)
    }

    @Test func mergeFailsCleanlyOnAnUnreadableFile() async throws {
        let folder = makeTemporaryDirectory()
        let a = TestPDFs.write(pages: 1, to: folder.appending(path: "a.pdf"))
        let broken = folder.appending(path: "broken.pdf")
        try Data("nope".utf8).write(to: broken)
        let work = MergeTool().work(inputs: [a, broken], options: NoOptions())
        await #expect(throws: FileToolError.unreadable("broken.pdf")) { try await runJob(work) }
    }

    @Test func splitRangesWriteNextToTheOriginal() async throws {
        let folder = makeTemporaryDirectory()
        let input = TestPDFs.write(pages: 5, to: folder.appending(path: "Report.pdf"))
        let options = SplitTool.Options(mode: .ranges, ranges: "1-2, 5")
        let report = try await runJob(SplitTool().work(inputs: [input], options: options))
        #expect(report.outputs.map(\.lastPathComponent) == ["Report (pages 1-2).pdf", "Report (page 5).pdf"])
        #expect(TestPDFs.pageTexts(report.outputs[0]) == ["Page 1", "Page 2"])
    }

    @Test func splitEachPageGoesIntoAFolder() async throws {
        let folder = makeTemporaryDirectory()
        let input = TestPDFs.write(pages: 3, to: folder.appending(path: "Report.pdf"))
        let report = try await runJob(SplitTool().work(inputs: [input], options: SplitTool.Options(mode: .eachPage)))
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Report (split)")
        let files = try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false)).sorted()
        #expect(files == ["Report-001.pdf", "Report-002.pdf", "Report-003.pdf"])
    }

    @Test func splitProblemExplainsBadRanges() {
        let folder = makeTemporaryDirectory()
        let input = TestPDFs.write(pages: 2, to: folder.appending(path: "Report.pdf"))
        #expect(SplitTool().problem(with: .init(mode: .ranges, ranges: "3"), inputs: [input]) == "There's no page 3: the PDF has 2 pages")
        #expect(SplitTool().problem(with: .init(mode: .ranges, ranges: "1-2"), inputs: [input]) == nil)
    }
}
