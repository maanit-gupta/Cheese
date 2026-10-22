import CoreGraphics
import Foundation
import Testing
@testable import Cheese

private let red = CanvasStyle(color: CanvasColor.presets[0], width: 4)
private let page: CanvasPageID = 1

private func stroke(_ points: [CGPoint], highlighter: Bool = false) -> CanvasItem {
    CanvasItem(kind: .stroke(points: points, isHighlighter: highlighter), style: red)
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, filled: Bool = false) -> CanvasItem {
    var style = red
    style.isFilled = filled
    return CanvasItem(kind: .shape(.rectangle, rect: CGRect(x: x, y: y, width: w, height: h)), style: style)
}

private func ellipse(_ frame: CGRect, filled: Bool = false) -> CanvasItem {
    var style = red
    style.isFilled = filled
    return CanvasItem(kind: .shape(.ellipse, rect: frame), style: style)
}

// MARK: - History

struct CanvasHistoryTests {
    @Test func addUndoRedo() {
        var document = CanvasDocument()
        var history = CanvasHistory()
        let item = stroke([.zero, CGPoint(x: 10, y: 10)])

        history.perform(.addItem(item, page: page), on: &document)
        #expect(document.items(on: page) == [item])
        #expect(history.canUndo && !history.canRedo)

        history.undo(&document)
        #expect(document.isEmpty)
        #expect(history.canRedo)

        history.redo(&document)
        #expect(document.items(on: page) == [item])
    }

    @Test func newCommandClearsRedo() {
        var document = CanvasDocument()
        var history = CanvasHistory()
        history.perform(.addItem(stroke([.zero]), page: page), on: &document)
        history.undo(&document)
        history.perform(.addItem(stroke([.zero]), page: page), on: &document)
        #expect(!history.canRedo)
    }

    @Test func removeItemsRestoresZOrderExactly() {
        var document = CanvasDocument()
        var history = CanvasHistory()
        let items = (0..<5).map { rect(CGFloat($0) * 10, 0, 5, 5) }
        for item in items {
            history.perform(.addItem(item, page: page), on: &document)
        }
        let removed = document.indexedItems(withIDs: [items[1].id, items[3].id], on: page)
        #expect(removed.map(\.index) == [3, 1])

        history.perform(.removeItems(removed, page: page), on: &document)
        #expect(document.items(on: page) == [items[0], items[2], items[4]])

        history.undo(&document)
        #expect(document.items(on: page) == items)
        history.redo(&document)
        #expect(document.items(on: page) == [items[0], items[2], items[4]])
    }

    @Test func liveErasingIsRecordedInRemovalOrder() {
        var document = CanvasDocument()
        var history = CanvasHistory()
        let items = (0..<4).map { rect(CGFloat($0) * 10, 0, 5, 5) }
        for item in items {
            document.insert(item, on: page)
        }
        // The eraser removes items one at a time as it touches them.
        let first = document.remove([items[0].id], on: page)
        let second = document.remove([items[2].id], on: page)
        history.record(.removeItems(first + second, page: page))

        history.undo(&document)
        #expect(document.items(on: page) == items)
    }

    @Test func transformAndEditTextRoundTrip() {
        var document = CanvasDocument()
        var history = CanvasHistory()
        let note = CanvasItem(kind: .sticky("", rect: CGRect(x: 0, y: 0, width: 200, height: 200), color: CanvasColor.stickyColors[0]), style: red)
        history.perform(.addItem(note, page: page), on: &document)

        let moved = note.translated(by: CGSize(width: 30, height: 40))
        history.perform(.transformItems(before: [note], after: [moved], page: page), on: &document)
        let edited = moved.withText("Ship it")
        history.perform(.editText(before: moved, after: edited, page: page), on: &document)
        #expect(document.item(note.id, on: page)?.text == "Ship it")
        #expect(document.item(note.id, on: page)?.geometryBounds.origin == CGPoint(x: 30, y: 40))

        history.undo(&document)
        #expect(document.item(note.id, on: page)?.text == "")
        history.undo(&document)
        #expect(document.item(note.id, on: page) == note)
    }

    @Test func clearAllCoversEveryDisplayAndUndoes() {
        var document = CanvasDocument()
        var history = CanvasHistory()
        history.perform(.addItem(stroke([.zero]), page: 1), on: &document)
        history.perform(.addItem(stroke([.zero]), page: 2), on: &document)
        let before = document

        history.perform(.clearAll(previous: document), on: &document)
        #expect(document.isEmpty)
        history.undo(&document)
        #expect(document == before)
        #expect(document.itemCount == 2)
    }

    @Test func undoWithNothingDoesNothing() {
        var document = CanvasDocument()
        var history = CanvasHistory()
        #expect(history.undo(&document) == nil)
        #expect(history.redo(&document) == nil)
    }
}

// MARK: - Items

struct CanvasItemTests {
    @Test func boundsIncludeHalfTheStroke() {
        let line = CanvasItem(kind: .line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 10)), style: red)
        #expect(line.geometryBounds == CGRect(x: 10, y: 10, width: 40, height: 0))
        #expect(line.bounds == CGRect(x: 8, y: 8, width: 44, height: 4))
    }

    @Test func highlighterIsWiderAndFlagged() {
        let marker = stroke([.zero, CGPoint(x: 10, y: 0)], highlighter: true)
        #expect(marker.isHighlighter)
        #expect(marker.renderedWidth == red.width * CanvasItem.highlighterWidthFactor)
    }

    @Test func translateMovesAllGeometry() {
        let moved = stroke([CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)]).translated(by: CGSize(width: 10, height: 20))
        #expect(moved.kind == .stroke(points: [CGPoint(x: 11, y: 22), CGPoint(x: 13, y: 24)], isHighlighter: false))
    }

    @Test func resizeMapsOldBoundsOntoNew() {
        let item = rect(10, 10, 100, 50)
        let resized = item.resized(from: CGRect(x: 10, y: 10, width: 100, height: 50), to: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(resized.kind == .shape(.rectangle, rect: CGRect(x: 0, y: 0, width: 200, height: 100)))
        #expect(resized.id == item.id)
    }

    @Test func resizingTextScalesItsFont() {
        var style = red
        style.fontSize = 20
        let text = CanvasItem(kind: .text("Hi", rect: CGRect(x: 0, y: 0, width: 40, height: 24)), style: style)
        let bigger = text.resized(from: CGRect(x: 0, y: 0, width: 40, height: 24), to: CGRect(x: 0, y: 0, width: 80, height: 48))
        #expect(bigger.style.fontSize == 40)
    }

    @Test func degenerateBoundsDontDivideByZero() {
        let line = CanvasItem(kind: .line(from: CGPoint(x: 0, y: 5), to: CGPoint(x: 10, y: 5)), style: red)
        let resized = line.resized(from: line.geometryBounds, to: CGRect(x: 0, y: 5, width: 20, height: 0))
        #expect(resized.kind == .line(from: CGPoint(x: 0, y: 5), to: CGPoint(x: 20, y: 5)))
    }
}

// MARK: - Smoothing

struct StrokeSmootherTests {
    @Test func keepsStartAndEnd() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 20, y: -3), CGPoint(x: 30, y: 4)]
        let smoothed = StrokeSmoother.smoothed(points)
        #expect(smoothed.first == points.first)
        #expect(smoothed.last == points.last)
    }

    @Test func straightInputStaysStraight() {
        let points = (0...10).map { CGPoint(x: CGFloat($0) * 10, y: CGFloat($0) * 5) }
        for point in StrokeSmoother.smoothed(points) {
            #expect(abs(point.y - point.x / 2) < 0.0001)
        }
    }

    @Test func zigzagIsSoftened() {
        let points = (0...10).map { CGPoint(x: CGFloat($0) * 10, y: $0.isMultiple(of: 2) ? 0 : 10) }
        let interior = StrokeSmoother.smoothed(points).dropFirst(6).dropLast(6)
        let peak = interior.map(\.y).max() ?? 0
        let trough = interior.map(\.y).min() ?? 0
        // The curve passes between the spikes rather than through them.
        #expect(peak < 10 && trough > 0)
    }

    @Test func tinyStrokes() {
        #expect(StrokeSmoother.smoothed([]).isEmpty)
        #expect(StrokeSmoother.smoothed([CGPoint(x: 3, y: 3)]) == [CGPoint(x: 3, y: 3)])
        let pair = StrokeSmoother.smoothed([.zero, CGPoint(x: 10, y: 0)])
        #expect(pair.first == .zero && pair.last == CGPoint(x: 10, y: 0))
        #expect(pair.allSatisfy { $0.y == 0 })
    }

    @Test func filteringDropsJitterButKeepsTheEnd() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5.2, y: 0), CGPoint(x: 5.4, y: 0)]
        #expect(StrokeSmoother.filtered(points, minimumDistance: 1) == [CGPoint(x: 0, y: 0), CGPoint(x: 5.4, y: 0)])
        #expect(StrokeSmoother.filtered([CGPoint(x: 1, y: 1)], minimumDistance: 1) == [CGPoint(x: 1, y: 1)])
        #expect(StrokeSmoother.filtered([], minimumDistance: 1).isEmpty)
    }
}

// MARK: - Hit testing

struct CanvasHitTesterTests {
    @Test func segmentDistance() {
        #expect(CanvasHitTester.distance(from: CGPoint(x: 5, y: 3), toSegment: .zero, CGPoint(x: 10, y: 0)) == 3)
        #expect(CanvasHitTester.distance(from: CGPoint(x: 13, y: 4), toSegment: .zero, CGPoint(x: 10, y: 0)) == 5)
        #expect(CanvasHitTester.distance(from: CGPoint(x: 3, y: 4), toSegment: .zero, .zero) == 5)
    }

    @Test func strokesAndLinesHitNearTheirPath() {
        let pen = stroke([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        #expect(CanvasHitTester.hits(pen, at: CGPoint(x: 50, y: 4), tolerance: 3, purpose: .select))
        #expect(!CanvasHitTester.hits(pen, at: CGPoint(x: 50, y: 20), tolerance: 3, purpose: .select))

        let arrow = CanvasItem(kind: .arrow(from: .zero, to: CGPoint(x: 0, y: 100)), style: red)
        #expect(CanvasHitTester.hits(arrow, at: CGPoint(x: 1, y: 60), tolerance: 2, purpose: .erase))
    }

    @Test func outlinedShapesEraseOnlyOnTheOutlineButSelectInside() {
        let box = rect(0, 0, 100, 100)
        let center = CGPoint(x: 50, y: 50)
        #expect(CanvasHitTester.hits(box, at: center, tolerance: 4, purpose: .select))
        #expect(!CanvasHitTester.hits(box, at: center, tolerance: 4, purpose: .erase))
        #expect(CanvasHitTester.hits(box, at: CGPoint(x: 99, y: 50), tolerance: 4, purpose: .erase))
        #expect(CanvasHitTester.hits(rect(0, 0, 100, 100, filled: true), at: center, tolerance: 4, purpose: .erase))
    }

    @Test func ellipses() {
        let circle = ellipse(CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(CanvasHitTester.hits(circle, at: CGPoint(x: 100, y: 50), tolerance: 2, purpose: .erase))
        #expect(!CanvasHitTester.hits(circle, at: CGPoint(x: 50, y: 50), tolerance: 2, purpose: .erase))
        #expect(CanvasHitTester.hits(circle, at: CGPoint(x: 50, y: 50), tolerance: 2, purpose: .select))
        // Just outside the corner of the bounding box is outside the circle.
        #expect(!CanvasHitTester.hits(circle, at: CGPoint(x: 3, y: 3), tolerance: 2, purpose: .select))
    }

    @Test func topItemPrefersLaterItemsAndPutsHighlightersBeneath() {
        let marker = stroke([CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)], highlighter: true)
        let lower = rect(0, 0, 100, 100, filled: true)
        let upper = rect(40, 40, 20, 20, filled: true)
        let items = [lower, upper, marker]
        #expect(CanvasHitTester.topItem(at: CGPoint(x: 50, y: 50), in: items, tolerance: 2)?.id == upper.id)
        #expect(CanvasHitTester.topItem(at: CGPoint(x: 10, y: 50), in: items, tolerance: 2)?.id == lower.id)
        #expect(CanvasHitTester.topItem(at: CGPoint(x: 10, y: 50), in: [marker], tolerance: 2)?.id == marker.id)
        #expect(CanvasHitTester.topItem(at: CGPoint(x: 500, y: 500), in: items, tolerance: 2) == nil)
    }

    @Test func eraserSweepsBetweenSamples() {
        let a = rect(100, 0, 10, 10, filled: true)
        let b = rect(300, 0, 10, 10, filled: true)
        let erased = CanvasHitTester.itemsErased(from: CGPoint(x: 0, y: 5), to: CGPoint(x: 400, y: 5), radius: 6, in: [a, b])
        #expect(erased == [a.id, b.id])
        #expect(CanvasHitTester.itemsErased(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 400, y: 50), radius: 6, in: [a, b]).isEmpty)
    }

    @Test func handlesAndResizing() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(CanvasHitTester.handle(at: CGPoint(x: 99, y: 49), of: box, radius: 5) == .bottomRight)
        #expect(CanvasHitTester.handle(at: CGPoint(x: 50, y: 25), of: box, radius: 5) == nil)

        let free = CanvasHitTester.resized(box, dragging: .bottomRight, to: CGPoint(x: 150, y: 150), keepAspect: false)
        #expect(free == CGRect(x: 0, y: 0, width: 150, height: 150))
        let kept = CanvasHitTester.resized(box, dragging: .bottomRight, to: CGPoint(x: 200, y: 60), keepAspect: true)
        #expect(kept == CGRect(x: 0, y: 0, width: 200, height: 100))
        // Dragging past the anchor flips to the other side instead of going negative.
        let flipped = CanvasHitTester.resized(box, dragging: .topLeft, to: CGPoint(x: 150, y: 80), keepAspect: false)
        #expect(flipped == CGRect(x: 100, y: 50, width: 50, height: 30))
        let tiny = CanvasHitTester.resized(box, dragging: .bottomRight, to: .zero, keepAspect: false)
        #expect(tiny.size == CGSize(width: 4, height: 4))
    }

    @Test func shiftConstraints() {
        let square = CanvasHitTester.shapeRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 20), constrained: true)
        #expect(square == CGRect(x: 10, y: 10, width: 30, height: 30))
        let upLeft = CanvasHitTester.shapeRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 0, y: -20), constrained: true)
        #expect(upLeft == CGRect(x: -20, y: -20, width: 30, height: 30))

        let snapped = CanvasHitTester.snappedEnd(from: .zero, to: CGPoint(x: 100, y: 10))
        #expect(abs(snapped.y) < 0.0001)
        let diagonal = CanvasHitTester.snappedEnd(from: .zero, to: CGPoint(x: 100, y: 90))
        #expect(abs(diagonal.x - diagonal.y) < 0.0001)
    }
}
