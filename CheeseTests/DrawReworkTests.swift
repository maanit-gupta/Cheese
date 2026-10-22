import AppKit
import Testing
@testable import Cheese

// MARK: - Fixtures

/// Recorded-style strokes in `Fixtures/Strokes/*.json`: `{"points": [[x, y, seconds], …]}`.
enum StrokeFixtures {
    private final class BundleToken {}

    private struct File: Decodable {
        var points: [[Double]]
    }

    static let shapes = ["rectangle-sloppy", "rectangle-mid-edge", "ellipse-sloppy", "circle-overshoot", "triangle", "tilted-square", "line-wobbly", "arrow"]
    static let freehand = ["handwriting-loops", "handwriting-hello", "spiral", "check-mark", "handwriting-www", "zigzag-slow"]

    static func samples(_ name: String) throws -> [InkSample] {
        let url = try #require(
            Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Strokes"),
            "Missing stroke fixture \(name).json"
        )
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return file.points.map { InkSample(point: CGPoint(x: $0[0], y: $0[1]), pressure: 1, time: $0[2]) }
    }

    static func points(_ name: String) throws -> [CGPoint] {
        try samples(name).map(\.point)
    }
}

// MARK: - Ink engine

struct StrokeBuilderTests {
    private func horizontal(from x0: CGFloat, to x1: CGFloat, step: CGFloat) -> [CGPoint] {
        stride(from: x0, through: x1, by: step).map { CGPoint(x: $0, y: 100) }
    }

    /// Half the outline's thickness across the middle of a horizontal stroke at y = 100.
    private func halfWidth(_ outline: [CGPoint], nearX x: CGFloat, within window: CGFloat = 6) -> CGFloat {
        outline.filter { abs($0.x - x) < window }.map { abs($0.y - 100) }.max() ?? 0
    }

    @Test func outlineIsAClosedPolygonAroundTheStroke() {
        let points = horizontal(from: 0, to: 300, step: 4)
        let outline = StrokeBuilder.outline(points: points, options: .pen(width: 8))
        #expect(outline.count > 10)
        // Every outline point stays within the brush of the input.
        for point in outline {
            #expect(CanvasHitTester.distance(from: point, toPolyline: points) <= 8 * 0.75 + 0.5)
        }
        #expect(!StrokeBuilder.path(points: points, options: .pen(width: 8)).isEmpty)
    }

    @Test func fasterIsThinner() {
        let slow = StrokeBuilder.outline(points: horizontal(from: 0, to: 400, step: 1), options: .pen(width: 10))
        let fast = StrokeBuilder.outline(points: horizontal(from: 0, to: 400, step: 12), options: .pen(width: 10))
        #expect(halfWidth(slow, nearX: 200) > halfWidth(fast, nearX: 200) + 1)
    }

    @Test func harderPressureIsThicker() {
        let points = horizontal(from: 0, to: 400, step: 4)
        let options = StrokeBuilder.Options.pen(width: 10, simulatesPressure: false)
        let light = StrokeBuilder.outline(points: points, pressures: Array(repeating: 0.15, count: points.count), options: options)
        let hard = StrokeBuilder.outline(points: points, pressures: Array(repeating: 0.95, count: points.count), options: options)
        #expect(halfWidth(hard, nearX: 200) > halfWidth(light, nearX: 200) * 1.5)
    }

    @Test func endsTaper() {
        let outline = StrokeBuilder.outline(points: horizontal(from: 0, to: 400, step: 3), options: .pen(width: 12))
        #expect(halfWidth(outline, nearX: 3) < halfWidth(outline, nearX: 200) * 0.6)
        #expect(halfWidth(outline, nearX: 397) < halfWidth(outline, nearX: 200) * 0.6)
    }

    @Test func highlighterKeepsAConstantWidth() {
        let outline = StrokeBuilder.outline(points: horizontal(from: 0, to: 300, step: 7), options: .highlighter(width: 20))
        for x in stride(from: CGFloat(40), through: 260, by: 40) {
            // The outline's own points are spaced out along a straight run, so look a little wider.
            #expect(abs(halfWidth(outline, nearX: x, within: 16) - 10) < 1)
        }
    }

    @Test func aClickIsADot() {
        let outline = StrokeBuilder.outline(points: [CGPoint(x: 50, y: 50)], options: .pen(width: 10))
        #expect(outline.count >= 10)
        for point in outline {
            let distance = hypot(point.x - 50, point.y - 50)
            #expect(distance > 2 && distance < 8)
        }
        #expect(StrokeBuilder.outline(points: [], options: .pen(width: 10)).isEmpty)
    }

    @Test func analogPressureIsTellsTabletsFromMice() {
        #expect(!StrokeBuilder.hasAnalogPressure([1, 1, 1]))
        #expect(!StrokeBuilder.hasAnalogPressure([0, 1]))
        #expect(!StrokeBuilder.hasAnalogPressure([]))
        #expect(StrokeBuilder.hasAnalogPressure([1, 0.4, 0.6]))
    }

    /// Building the live stroke happens once per frame, so even a long stroke must take a
    /// fraction of a 120 Hz frame (8 ms).
    @Test func longStrokesBuildWithinAFrame() {
        let points = (0..<2000).map { CGPoint(x: CGFloat($0) * 0.8, y: 300 + 80 * sin(CGFloat($0) / 40)) }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<5 {
                _ = StrokeBuilder.path(points: points, options: .pen(width: 6))
            }
        }
        #expect(elapsed / 5 < .milliseconds(8))
    }
}

struct OneEuroFilterTests {
    @Test func firstSamplePassesThrough() {
        var filter = OneEuroFilter()
        #expect(filter.filter(CGPoint(x: 10, y: 20), at: 1) == CGPoint(x: 10, y: 20))
    }

    @Test func stillPointerJitterIsDamped() {
        var filter = OneEuroFilter()
        var outputs: [CGPoint] = []
        for index in 0..<240 {
            let jitter: CGFloat = index.isMultiple(of: 2) ? 1.5 : -1.5
            outputs.append(filter.filter(CGPoint(x: 100 + jitter, y: 100 - jitter), at: Double(index) / 120))
        }
        let settled = outputs.suffix(120)
        let spread = (settled.map(\.x).max() ?? 0) - (settled.map(\.x).min() ?? 0)
        #expect(spread < 1)
    }

    @Test func fastStrokesBarelyLag() {
        var filter = OneEuroFilter()
        var output = CGPoint.zero
        for index in 0..<60 {
            // 2,400 points per second.
            output = filter.filter(CGPoint(x: CGFloat(index) * 20, y: 0), at: Double(index) / 120)
        }
        #expect(59 * 20 - output.x < 40)
    }

    @Test func repeatedTimestampsDontBreakIt() {
        var filter = OneEuroFilter()
        _ = filter.filter(.zero, at: 0)
        let next = filter.filter(CGPoint(x: 10, y: 0), at: 0)
        #expect(next.x.isFinite && next.x > 0 && next.x <= 10)
    }
}

// MARK: - Rendering invalidation

struct CanvasRasterTests {
    private let style = CanvasStyle(color: CanvasColor.presets[0], width: 4)

    private func ink(_ x: CGFloat, highlighter: Bool = false) -> CanvasItem {
        CanvasItem(kind: .stroke(points: [CGPoint(x: x, y: 0), CGPoint(x: x + 10, y: 10)], pressures: [], isHighlighter: highlighter), style: style)
    }

    @Test func committingPaintsOnlyTheNewItem() {
        let a = ink(0), b = ink(20)
        #expect(CanvasRaster.update(from: [a], to: [a, b]) == .append([b]))
        #expect(CanvasRaster.update(from: [], to: [a]) == .append([a]))
        #expect(CanvasRaster.update(from: [a, b], to: [a, b]) == .none)
    }

    @Test func undoEraseMoveAndClearRepaint() {
        let a = ink(0), b = ink(20)
        #expect(CanvasRaster.update(from: [a, b], to: [a]) == .full)
        #expect(CanvasRaster.update(from: [a, b], to: [a, b.translated(by: CGSize(width: 5, height: 0))]) == .full)
        #expect(CanvasRaster.update(from: [a, b], to: []) == .full)
    }

    @Test func aHighlighterUnderExistingInkRepaints() {
        let pen = ink(0), marker = ink(20, highlighter: true)
        let before = CanvasRaster.drawOrder([pen])
        let after = CanvasRaster.drawOrder([pen, marker])
        #expect(after == [marker, pen])
        #expect(CanvasRaster.update(from: before, to: after) == .full)
        // Over highlighters alone, it's just painted on top.
        let other = ink(40, highlighter: true)
        #expect(CanvasRaster.update(from: [marker], to: CanvasRaster.drawOrder([marker, other])) == .append([other]))
    }

    /// The 501st stroke costs the same as the first: only it is painted.
    @Test func frameCostStaysFlatWithManyStrokes() {
        let strokes = (0..<500).map { ink(CGFloat($0)) }
        let next = ink(9999)
        #expect(CanvasRaster.update(from: strokes, to: strokes + [next]) == .append([next]))
    }
}

// MARK: - Radial menu

struct RadialMenuGeometryTests {
    private let geometry = RadialMenuGeometry()

    @Test func slicesGoClockwiseFromTheTop() {
        #expect(RadialMenuGeometry.slice(for: CGVector(dx: 0, dy: -50)) == 0)
        #expect(RadialMenuGeometry.slice(for: CGVector(dx: 40, dy: -40)) == 1)
        #expect(RadialMenuGeometry.slice(for: CGVector(dx: 50, dy: 0)) == 2)
        #expect(RadialMenuGeometry.slice(for: CGVector(dx: 0, dy: 50)) == 4)
        #expect(RadialMenuGeometry.slice(for: CGVector(dx: -50, dy: 0)) == 6)
        #expect(RadialMenuGeometry.slice(for: CGVector(dx: -40, dy: -40)) == 7)
        // Just either side of the top boundary.
        #expect(RadialMenuGeometry.slice(for: CGVector(dx: 10, dy: -50)) == 0)
        #expect(RadialMenuGeometry.slice(for: CGVector(dx: -10, dy: -50)) == 0)
    }

    @Test func slicesMatchTheSpecsLayout() {
        #expect(RadialSlice.allCases.map(\.tool) == [.pen, .highlighter, .eraser, .text, .stamp, .sticky, .zoom, .laser])
    }

    @Test func distancePicksCancelSliceOrColor() {
        #expect(geometry.target(at: CGVector(dx: 5, dy: 5)) == .cancel)
        #expect(geometry.target(at: CGVector(dx: 0, dy: -60)) == .slice(0))
        #expect(geometry.target(at: CGVector(dx: 0, dy: 120)) == .color(4))
        // Overshooting the ring still picks its color.
        #expect(geometry.target(at: CGVector(dx: 300, dy: 0)) == .color(2))
    }

    @Test func flicksNeedDistanceAndSpeed() {
        #expect(RadialMenuGeometry.flick(displacement: CGVector(dx: 60, dy: 0), duration: 0.08) == 2)
        #expect(RadialMenuGeometry.flick(displacement: CGVector(dx: 0, dy: 60), duration: 0.1) == 4)
        #expect(RadialMenuGeometry.flick(displacement: CGVector(dx: 10, dy: 0), duration: 0.01) == nil)
        #expect(RadialMenuGeometry.flick(displacement: CGVector(dx: 60, dy: 0), duration: 2) == nil)
    }

    @Test func iconsSitInTheirSlices() {
        for index in 0..<RadialMenuGeometry.sliceCount {
            #expect(geometry.target(at: geometry.center(ofSlice: index)) == .slice(index))
            #expect(geometry.target(at: geometry.center(ofSwatch: index)) == .color(index))
        }
    }

    @Test func theMenuStaysOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let center = geometry.clampedCenter(CGPoint(x: 2, y: 790), in: bounds)
        #expect(center.x >= geometry.ringRadius && center.y <= 800 - geometry.ringRadius)
        #expect(geometry.clampedCenter(CGPoint(x: 500, y: 400), in: bounds) == CGPoint(x: 500, y: 400))
    }
}

// MARK: - Tap or hold the hotkey

struct DrawHotkeyGestureTests {
    @Test func aTapTurnsDrawModeOnAndAnotherTurnsItOff() {
        var gesture = DrawHotkeyGesture()
        #expect(gesture.press(at: 0, isActive: false, isPassThrough: false) == .enter)
        #expect(gesture.release(at: 0.1) == .stay)
        #expect(gesture.press(at: 5, isActive: true, isPassThrough: false) == .none)
        #expect(gesture.release(at: 5.1) == .exit)
    }

    @Test func holdingIsQuickInk() {
        var gesture = DrawHotkeyGesture()
        #expect(gesture.press(at: 0, isActive: false, isPassThrough: false) == .enter)
        #expect(gesture.isHeld)
        #expect(gesture.release(at: 2) == .passThrough)
        #expect(!gesture.isHeld)
        // From pass-through, holding takes the mouse back to ink, then hands it back.
        #expect(gesture.press(at: 10, isActive: true, isPassThrough: true) == .resumeDrawing)
        #expect(gesture.release(at: 11) == .passThrough)
    }

    @Test func theThresholdIsAQuarterSecond() {
        var gesture = DrawHotkeyGesture()
        _ = gesture.press(at: 0, isActive: false, isPassThrough: false)
        #expect(gesture.release(at: 0.249) == .stay)
        _ = gesture.press(at: 1, isActive: true, isPassThrough: false)
        #expect(gesture.release(at: 1.25) == .passThrough)
    }

    @Test func keyRepeatAndStrayReleasesAreIgnored() {
        var gesture = DrawHotkeyGesture()
        #expect(gesture.release(at: 0) == .none)
        _ = gesture.press(at: 0, isActive: false, isPassThrough: false)
        #expect(gesture.press(at: 0.05, isActive: true, isPassThrough: false) == .none)
        #expect(gesture.release(at: 0.1) == .stay)
        _ = gesture.press(at: 1, isActive: true, isPassThrough: false)
        gesture.cancel()
        #expect(gesture.release(at: 1.1) == .none)
    }
}

// MARK: - Magic pen and scratch-out

struct ShapeRecognizerTests {
    @Test(arguments: StrokeFixtures.shapes)
    func roughShapesSnap(_ name: String) throws {
        let shape = try #require(ShapeRecognizer.recognize(try StrokeFixtures.points(name)), "\(name) wasn't recognized")
        switch (name, shape) {
        case ("rectangle-sloppy", .rectangle(let rect)):
            #expect(abs(rect.minX - 100) < 10 && abs(rect.maxX - 340) < 10 && abs(rect.minY - 100) < 10 && abs(rect.maxY - 250) < 10)
        case ("rectangle-mid-edge", .rectangle(let rect)):
            #expect(abs(rect.width - 320) < 15 && abs(rect.height - 120) < 15)
        case ("ellipse-sloppy", .ellipse(let rect)), ("circle-overshoot", .ellipse(let rect)):
            #expect(rect.width > 150 && rect.height > 150 || name == "ellipse-sloppy")
        case ("triangle", .polygon(let corners)):
            #expect(corners.count == 3)
        case ("tilted-square", .polygon(let corners)):
            #expect(corners.count == 4)
        case ("line-wobbly", .line(let from, let to)):
            #expect(hypot(from.x - 80, from.y - 300) < 10 && hypot(to.x - 420, to.y - 220) < 10)
        case ("arrow", .arrow(let from, let to)):
            #expect(hypot(from.x - 80, from.y - 300) < 10 && hypot(to.x - 360, to.y - 180) < 15)
        default:
            Issue.record("\(name) was recognized as \(shape)")
        }
    }

    @Test(arguments: StrokeFixtures.freehand)
    func handwritingStaysFreehand(_ name: String) throws {
        #expect(ShapeRecognizer.recognize(try StrokeFixtures.points(name)) == nil)
    }

    @Test func tinyStrokesNeverSnap() {
        let dot = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 5), CGPoint(x: 0, y: 5), CGPoint(x: 0, y: 0)]
        #expect(ShapeRecognizer.recognize(dot) == nil)
    }

    @Test func aFastZigZagIsAScratchOut() throws {
        #expect(ShapeRecognizer.isScratchOut(try StrokeFixtures.samples("scratch-out")))
    }

    @Test(arguments: ["zigzag-slow", "handwriting-www", "handwriting-hello", "line-wobbly", "rectangle-sloppy"])
    func otherStrokesArent(_ name: String) throws {
        #expect(!ShapeRecognizer.isScratchOut(try StrokeFixtures.samples(name)))
    }

    @Test func reversalsNeedToClearTheThreshold() {
        #expect(ShapeRecognizer.reversals([0, 10, 0, 10, 0], threshold: 5) == 3)
        #expect(ShapeRecognizer.reversals([0, 10, 8, 20, 18, 30], threshold: 5) == 0)
    }
}

// MARK: - Model additions

struct DrawReworkModelTests {
    private let style = CanvasStyle(color: CanvasColor.presets[4], width: 5)

    @Test func retractLeavesNothingToRedo() {
        var document = CanvasDocument()
        var history = CanvasHistory()
        let item = CanvasItem(kind: .line(from: .zero, to: CGPoint(x: 5, y: 5)), style: style)
        history.perform(.addItem(item, page: 1), on: &document)
        #expect(history.retract(&document) == .addItem(item, page: 1))
        #expect(document.isEmpty)
        #expect(!history.canUndo && !history.canRedo)
    }

    @Test func stepNumbersContinueFromTheHighest() {
        let stamps = [3, 1].map { CanvasItem(kind: .stamp(.number($0), center: .zero, size: 30), style: style) }
        #expect(StampKind.nextStepNumber(in: []) == 1)
        #expect(StampKind.nextStepNumber(in: stamps) == 4)
        #expect(StampKind.number.stamp(after: stamps) == .number(4))
        #expect(StampKind.star.stamp(after: stamps) == .star)
        #expect(StampKind.number.next == .check)
    }

    @Test func stampsAndPolygonsMoveResizeAndHit() {
        let stamp = CanvasItem(kind: .stamp(.check, center: CGPoint(x: 50, y: 50), size: 40), style: style)
        #expect(stamp.bounds == CGRect(x: 30, y: 30, width: 40, height: 40))
        #expect(stamp.translated(by: CGSize(width: 10, height: 0)).bounds.minX == 40)
        #expect(stamp.resized(from: stamp.bounds, to: CGRect(x: 30, y: 30, width: 80, height: 80)).bounds.width == 80)
        #expect(CanvasHitTester.hits(stamp, at: CGPoint(x: 50, y: 50), tolerance: 0, purpose: .erase))

        let triangle = CanvasItem(kind: .polygon(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: 80)]), style: style)
        #expect(CanvasHitTester.hits(triangle, at: CGPoint(x: 50, y: 30), tolerance: 2, purpose: .select))
        #expect(!CanvasHitTester.hits(triangle, at: CGPoint(x: 50, y: 30), tolerance: 2, purpose: .erase))
        #expect(CanvasHitTester.hits(triangle, at: CGPoint(x: 50, y: 1), tolerance: 2, purpose: .erase))
    }

    @MainActor
    @Test func colorsCycleThroughThePresets() {
        let settings = DrawSettings()
        settings.color = CanvasColor.presets[8]
        settings.cycleColor(forward: true)
        #expect(settings.color == CanvasColor.presets[0])
        settings.cycleColor(forward: false)
        #expect(settings.color == CanvasColor.presets[8])
        settings.color = CanvasColor(red: 0.1, green: 0.2, blue: 0.3)
        settings.cycleColor(forward: true)
        #expect(settings.color == CanvasColor.presets[0])
    }

    @Test func straightLinesSnapTo15Degrees() {
        let end = CanvasHitTester.snappedEnd(from: .zero, to: CGPoint(x: 100, y: 30), step: .pi / 12)
        #expect(abs(atan2(end.y, end.x) - .pi / 12) < 0.0001)
    }
}

// MARK: - Mouse-first draw mode

/// Drives the controller with synthesized events and the default settings: letter keys off.
@MainActor
struct MouseFirstDrawTests {
    private let page: CanvasPageID = 3
    private let controller = DrawModeController(services: DrawModeController.Services(
        captureDisplay: { _, _ in throw CaptureError.displayNotFound },
        openEditor: { _ in },
        isScreenRecordingGranted: { false },
        explainMissingScreenRecording: { _ in },
        usesLetterKeys: { false }
    ))

    private var items: [CanvasItem] { controller.document.items(on: page) }

    private func mouse(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = [], time: TimeInterval = 0, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: time,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
        ) ?? NSEvent()
    }

    private func key(_ characters: String, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) ?? NSEvent()
    }

    /// Draws through `points`, 120 samples a second.
    private func stroke(_ points: [CGPoint], _ flags: NSEvent.ModifierFlags = [], start: TimeInterval = 0, pause: Bool = false) {
        guard let first = points.first, let last = points.last else { return }
        controller.mouseDown(on: page, at: first, event: mouse(.leftMouseDown, flags, time: start))
        for (index, point) in points.enumerated().dropFirst() {
            controller.mouseDragged(on: page, at: point, event: mouse(.leftMouseDragged, flags, time: start + Double(index) / 120))
        }
        if pause {
            controller.pauseElapsed()
        }
        controller.mouseUp(on: page, at: last, event: mouse(.leftMouseUp, flags, time: start + Double(points.count) / 120))
    }

    private func line(from a: CGPoint, to b: CGPoint, steps: Int = 30) -> [CGPoint] {
        (0...steps).map { CGPoint(x: a.x + (b.x - a.x) * CGFloat($0) / CGFloat(steps), y: a.y + (b.y - a.y) * CGFloat($0) / CGFloat(steps)) }
    }

    @Test func thePenIsTheDefaultAndLettersDoNothing() {
        #expect(controller.settings.tool == .pen)
        #expect(!controller.handleKeyDown(key("r")))
        #expect(!controller.handleKeyDown(key("5")))
        #expect(controller.settings.tool == .pen)
        // Undo and Esc stay.
        #expect(controller.handleKeyDown(key("z", flags: .command)))
    }

    @Test func thePenDrawsVariableWidthInk() {
        stroke(line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 50)))
        guard case let .stroke(points, pressures, isHighlighter)? = items.first?.kind else {
            Issue.record("Expected a stroke")
            return
        }
        #expect(!isHighlighter)
        #expect(pressures.isEmpty)
        #expect(points.last == CGPoint(x: 200, y: 50))
    }

    @Test func optionHighlightsCommandErasesShiftStraightens() {
        stroke(line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 0)), .option)
        #expect(items.first?.isHighlighter == true)

        stroke(line(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 200, y: 115)), .shift)
        guard case let .line(from, to)? = items.last?.kind else {
            Issue.record("Expected a straight line")
            return
        }
        #expect(from == CGPoint(x: 0, y: 100))
        // 15 points over 200 is about 4°, which snaps to horizontal.
        #expect(abs(to.y - 100) < 0.001)
        #expect(items.count == 2)

        stroke(line(from: CGPoint(x: 100, y: -20), to: CGPoint(x: 100, y: 150)), .command)
        #expect(items.isEmpty)
        // ⌘-erasing is one undo step.
        controller.undo()
        #expect(items.count == 2)
    }

    @Test func scrollingSizesTheBrushAndShiftScrollingChangesColor() {
        let width = controller.settings.width
        controller.scrolled(on: page, at: .zero, delta: 1, precise: false, modifiers: [])
        #expect(controller.settings.width > width)
        controller.scrolled(on: page, at: .zero, delta: -1, precise: false, modifiers: [])
        controller.scrolled(on: page, at: .zero, delta: -1, precise: false, modifiers: [])
        #expect(controller.settings.width < width)
        // Small trackpad deltas add up before a step.
        let before = controller.settings.width
        controller.scrolled(on: page, at: .zero, delta: 4, precise: true, modifiers: [])
        #expect(controller.settings.width == before)
        controller.scrolled(on: page, at: .zero, delta: 10, precise: true, modifiers: [])
        #expect(controller.settings.width > before)

        controller.scrolled(on: page, at: .zero, delta: 1, precise: false, modifiers: .shift)
        #expect(controller.settings.color == CanvasColor.presets[1])
    }

    @Test func doubleClickingEmptySpaceStartsATextBox() {
        let point = CGPoint(x: 40, y: 40)
        controller.mouseDown(on: page, at: point, event: mouse(.leftMouseDown))
        controller.mouseUp(on: page, at: point, event: mouse(.leftMouseUp))
        #expect(items.count == 1)
        controller.mouseDown(on: page, at: point, event: mouse(.leftMouseDown, clicks: 2))
        // The first click's dot is gone, with nothing left to redo, and a text box is open.
        #expect(items.isEmpty)
        #expect(!controller.settings.canRedo)
        #expect(controller.isEditingText)
        controller.setEditingText("Hello")
        controller.endTextEditing()
        guard case let .text(text, _)? = items.first?.kind else {
            Issue.record("Expected text")
            return
        }
        #expect(text == "Hello")
    }

    @Test func flicksPickToolsAndColors() {
        // Right, quickly: the eraser.
        controller.radialBegan(on: page, at: CGPoint(x: 300, y: 300), time: 10)
        controller.radialEnded(on: page, at: CGPoint(x: 370, y: 300), time: 10.08)
        #expect(controller.settings.tool == .eraser)
        // Down: stamps; down again: the next stamp.
        controller.radialBegan(on: page, at: CGPoint(x: 300, y: 300), time: 20)
        controller.radialEnded(on: page, at: CGPoint(x: 300, y: 360), time: 20.08)
        #expect(controller.settings.tool == .stamp)
        let kind = controller.settings.stampKind
        controller.radialBegan(on: page, at: CGPoint(x: 300, y: 300), time: 30)
        controller.radialEnded(on: page, at: CGPoint(x: 300, y: 360), time: 30.08)
        #expect(controller.settings.stampKind == kind.next)
        // A plain right-click picks nothing.
        controller.radialBegan(on: page, at: CGPoint(x: 300, y: 300), time: 40)
        controller.radialEnded(on: page, at: CGPoint(x: 301, y: 300), time: 40.05)
        #expect(controller.settings.tool == .stamp)
    }

    @Test func numberedStepsCountUp() {
        controller.chooseTool(.stamp)
        controller.settings.stampKind = .number
        for x in [10, 60, 110] {
            controller.mouseDown(on: page, at: CGPoint(x: x, y: 10), event: mouse(.leftMouseDown))
            controller.mouseUp(on: page, at: CGPoint(x: x, y: 10), event: mouse(.leftMouseUp))
        }
        let numbers = items.compactMap { item -> Int? in
            if case let .stamp(.number(number), _, _) = item.kind { return number }
            return nil
        }
        #expect(numbers == [1, 2, 3])
        controller.undo()
        controller.mouseDown(on: page, at: CGPoint(x: 200, y: 10), event: mouse(.leftMouseDown))
        #expect(items.count == 3)
        if case let .stamp(.number(number), _, _)? = items.last?.kind {
            #expect(number == 3)
        }
    }

    @Test func pausingTheMagicPenSnapsARoughShape() throws {
        stroke(try StrokeFixtures.points("rectangle-sloppy"), pause: true)
        guard case .shape(.rectangle, _)? = items.first?.kind else {
            Issue.record("Expected a clean rectangle, got \(String(describing: items.first?.kind))")
            return
        }
        // Without the pause it stays freehand.
        stroke(try StrokeFixtures.points("rectangle-sloppy"), start: 10)
        guard case .stroke? = items.last?.kind else {
            Issue.record("Expected freehand")
            return
        }
    }

    @Test func scratchingOutDeletesTheInkUnderneath() throws {
        let scratch = try StrokeFixtures.samples("scratch-out")
        // A word under the scratch, and one well away from it.
        stroke(line(from: CGPoint(x: 120, y: 210), to: CGPoint(x: 300, y: 210)))
        stroke(line(from: CGPoint(x: 120, y: 600), to: CGPoint(x: 300, y: 600)), start: 1)
        #expect(items.count == 2)
        controller.mouseDown(on: page, at: scratch[0].point, event: mouse(.leftMouseDown, time: 100 + scratch[0].time))
        for sample in scratch.dropFirst() {
            controller.mouseDragged(on: page, at: sample.point, event: mouse(.leftMouseDragged, time: 100 + sample.time))
        }
        controller.mouseUp(on: page, at: scratch[scratch.count - 1].point, event: mouse(.leftMouseUp, time: 100 + scratch[scratch.count - 1].time))
        #expect(items.count == 1)
        #expect(items.first?.geometryBounds.minY ?? 0 > 500)
        controller.undo()
        #expect(items.count == 2)
    }

    @Test func aScratchOverNothingIsJustInk() throws {
        let scratch = try StrokeFixtures.samples("scratch-out")
        controller.mouseDown(on: page, at: scratch[0].point, event: mouse(.leftMouseDown, time: scratch[0].time))
        for sample in scratch.dropFirst() {
            controller.mouseDragged(on: page, at: sample.point, event: mouse(.leftMouseDragged, time: sample.time))
        }
        controller.mouseUp(on: page, at: scratch[scratch.count - 1].point, event: mouse(.leftMouseUp, time: 1))
        #expect(items.count == 1)
    }

    @Test func disappearingInkNeverEntersTheDocument() {
        controller.settings.isDisappearingInk = true
        stroke(line(from: .zero, to: CGPoint(x: 100, y: 100)))
        #expect(items.isEmpty)
        #expect(!controller.settings.canUndo)
    }

    @Test func neonOnlyGlowsPenInk() {
        controller.settings.isNeon = true
        stroke(line(from: .zero, to: CGPoint(x: 100, y: 0)))
        stroke(line(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 50)), .option)
        #expect(items.map(\.style.isNeon) == [true, false])
    }
}

// MARK: - Palette and hotkeys

@MainActor
struct DrawPaletteTests {
    @Test func drawModeIsKeptOutOfThePalette() {
        let draw = DrawModule(services: DrawModeController.Services(
            captureDisplay: { _, _ in throw CaptureError.displayNotFound },
            openEditor: { _ in },
            isScreenRecordingGranted: { false },
            explainMissingScreenRecording: { _ in }
        ))
        #expect(CommandPaletteModule.entries(from: draw.actions).isEmpty)
        #expect(draw.actions.first?.hotkeyHandler != nil)
    }

    @Test func thePaletteIsOffWhileSuppressed() {
        var drawing = true
        let palette = CommandPaletteModule(availableActions: { [] }, perform: { _, _ in }, isSuppressed: { drawing })
        let action = palette.actions[0]
        #expect(!action.precondition())
        drawing = false
        #expect(action.precondition())
    }

    @Test func releasesOnlyReachActionsThatHandleThem() {
        var pressed = 0
        var events: [String] = []
        let plain = CheeseAction(id: ActionID(rawValue: "plain"), title: "Plain", symbol: "star", module: nil) { _ in pressed += 1 }
        let holdable = CheeseAction(
            id: ActionID(rawValue: "holdable"), title: "Holdable", symbol: "star", module: nil,
            hotkeyHandler: { event in events.append(event == .keyDown ? "down" : "up") }
        ) { _ in pressed += 100 }
        let registry = ActionRegistry(appActions: [plain, holdable], moduleManager: ModuleManager(modules: []) { _ in true }, permissions: SystemPermissions()) { _, _ in }
        registry.handleHotkey(.keyDown, for: plain.id)
        registry.handleHotkey(.keyUp, for: plain.id)
        #expect(pressed == 1)
        registry.handleHotkey(.keyDown, for: holdable.id)
        registry.handleHotkey(.keyUp, for: holdable.id)
        #expect(events == ["down", "up"])
        #expect(pressed == 1)
    }
}
