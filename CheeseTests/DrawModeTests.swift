import AppKit
import Testing
@testable import Cheese

struct DrawToolTests {
    @Test func everyToolHasTheSpecsKey() {
        let expected: [DrawTool: Character] = [
            .select: "V", .passThrough: "M", .pen: "P", .highlighter: "H", .eraser: "E",
            .rectangle: "R", .ellipse: "O", .line: "I", .arrow: "A", .text: "T", .sticky: "N",
            .laser: "L", .spotlight: "S", .zoom: "Z",
        ]
        #expect(expected.count == DrawTool.allCases.count)
        for tool in DrawTool.allCases {
            #expect(tool.key == expected[tool])
            #expect(DrawTool.forKey(Character(tool.key.lowercased())) == tool)
        }
        // B (boards) and digits aren't tools.
        #expect(DrawTool.forKey("b") == nil)
        #expect(DrawTool.forKey("1") == nil)
    }

    @Test func boardsCycle() {
        #expect(BoardMode.off.next == .whiteboard)
        #expect(BoardMode.whiteboard.next == .blackboard)
        #expect(BoardMode.blackboard.next == .off)
    }

    @Test func presenterToolsDontMakeItems() {
        #expect(DrawTool.allCases.filter(\.isPresenter) == [.laser, .spotlight, .zoom])
    }

    @MainActor
    @Test func widthStepsStayInRange() {
        let settings = DrawSettings()
        settings.width = 5
        settings.adjustWidth(thicker: true)
        #expect(settings.width == 6)
        settings.width = 20
        settings.adjustWidth(thicker: true)
        #expect(settings.width == 25)
        settings.adjustWidth(thicker: false)
        #expect(settings.width == 20)
        settings.width = 1
        settings.adjustWidth(thicker: false)
        #expect(settings.width == 1)
        settings.width = 40
        settings.adjustWidth(thicker: true)
        #expect(settings.width == 40)
    }
}

/// Drives the controller with synthesized events, without putting overlays on screen.
@MainActor
struct DrawModeControllerTests {
    private let page: CanvasPageID = 7
    private let controller = DrawModeController(services: DrawModeController.Services(
        captureDisplay: { _, _ in throw CaptureError.displayNotFound },
        openEditor: { _ in },
        isScreenRecordingGranted: { false },
        explainMissingScreenRecording: { _ in }
    ))

    private func mouse(_ type: NSEvent.EventType, shift: Bool = false, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
        ) ?? NSEvent()
    }

    private func key(_ characters: String, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) ?? NSEvent()
    }

    private func drag(from start: CGPoint, to end: CGPoint, shift: Bool = false) {
        controller.mouseDown(on: page, at: start, event: mouse(.leftMouseDown, shift: shift))
        controller.mouseDragged(on: page, at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), event: mouse(.leftMouseDragged, shift: shift))
        controller.mouseDragged(on: page, at: end, event: mouse(.leftMouseDragged, shift: shift))
        controller.mouseUp(on: page, at: end, event: mouse(.leftMouseUp, shift: shift))
    }

    private var items: [CanvasItem] { controller.document.items(on: page) }

    @Test func letterKeysPickTools() {
        #expect(controller.handleKeyDown(key("r")))
        #expect(controller.settings.tool == .rectangle)
        #expect(controller.handleKeyDown(key("O")))
        #expect(controller.settings.tool == .ellipse)
        // Zoom needs Screen Recording, which isn't granted here: the tool doesn't change.
        #expect(controller.handleKeyDown(key("z")))
        #expect(controller.settings.tool == .ellipse)
    }

    @Test func digitsBracketsAndBoards() {
        #expect(controller.handleKeyDown(key("5")))
        #expect(controller.settings.color == CanvasColor.presets[4])
        let width = controller.settings.width
        #expect(controller.handleKeyDown(key("]")))
        #expect(controller.settings.width > width)
        #expect(controller.handleKeyDown(key("b")))
        #expect(controller.settings.board == .whiteboard)
        #expect(!controller.handleKeyDown(key("q")))
    }

    @Test func passThroughOnlyListensForM() {
        controller.chooseTool(.highlighter)
        #expect(controller.handleKeyDown(key("m")))
        #expect(controller.settings.tool == .passThrough)
        #expect(!controller.handleKeyDown(key("p")))
        #expect(controller.settings.tool == .passThrough)
        #expect(controller.handleKeyDown(key("m")))
        #expect(controller.settings.tool == .highlighter)
    }

    @Test func dragsMakeShapesAndShiftConstrains() {
        controller.chooseTool(.rectangle)
        drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 30), shift: true)
        #expect(items.count == 1)
        #expect(items.first?.kind == .shape(.rectangle, rect: CGRect(x: 10, y: 10, width: 50, height: 50)))

        controller.chooseTool(.arrow)
        drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 4), shift: true)
        if case let .arrow(_, to) = items.last?.kind {
            #expect(abs(to.y) < 0.001)
        } else {
            Issue.record("Expected an arrow")
        }

        // A click without a drag adds nothing.
        controller.chooseTool(.ellipse)
        drag(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 6, y: 6))
        #expect(items.count == 2)
    }

    @Test func undoRedoWithCommandZ() {
        controller.chooseTool(.line)
        drag(from: .zero, to: CGPoint(x: 50, y: 50))
        #expect(controller.settings.canUndo)
        #expect(controller.handleKeyDown(key("z", flags: .command)))
        #expect(items.isEmpty)
        #expect(controller.settings.canRedo)
        #expect(controller.handleKeyDown(key("Z", flags: [.command, .shift])))
        #expect(items.count == 1)
    }

    @Test func eraserRemovesWholeItemsInOneUndoStep() {
        controller.chooseTool(.line)
        drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 100))
        drag(from: CGPoint(x: 50, y: 0), to: CGPoint(x: 50, y: 100))
        drag(from: CGPoint(x: 200, y: 0), to: CGPoint(x: 200, y: 100))
        controller.chooseTool(.eraser)
        drag(from: CGPoint(x: -20, y: 50), to: CGPoint(x: 70, y: 50))
        #expect(items.count == 1)
        controller.undo()
        #expect(items.count == 3)
    }

    @Test func selectMoveAndDelete() {
        controller.chooseTool(.rectangle)
        drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 40, y: 40))
        let original = items[0]

        controller.chooseTool(.select)
        drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 70))
        #expect(items[0].geometryBounds.origin == CGPoint(x: 100, y: 50))
        controller.undo()
        #expect(items[0] == original)

        controller.mouseDown(on: page, at: CGPoint(x: 20, y: 20), event: mouse(.leftMouseDown))
        controller.mouseUp(on: page, at: CGPoint(x: 20, y: 20), event: mouse(.leftMouseUp))
        #expect(controller.handleKeyDown(key("\u{7f}", keyCode: 51)))
        #expect(items.isEmpty)
        controller.undo()
        #expect(items == [original])
    }

    @Test func resizeFromAHandle() {
        controller.chooseTool(.rectangle)
        controller.settings.width = 2
        drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100))
        controller.chooseTool(.select)
        controller.mouseDown(on: page, at: CGPoint(x: 50, y: 50), event: mouse(.leftMouseDown))
        controller.mouseUp(on: page, at: CGPoint(x: 50, y: 50), event: mouse(.leftMouseUp))
        // The bottom-right handle sits just outside the item's bounds.
        let corner = CGPoint(x: items[0].bounds.maxX + 4, y: items[0].bounds.maxY + 4)
        drag(from: corner, to: CGPoint(x: corner.x + 100, y: corner.y + 100))
        #expect(items[0].geometryBounds.width > 150)
        controller.undo()
        #expect(items[0].geometryBounds.width == 100)
    }

    @Test func clearAllWithFewItemsDoesntAskAndUndoes() {
        controller.chooseTool(.line)
        for index in 0..<3 {
            drag(from: CGPoint(x: CGFloat(index) * 20, y: 0), to: CGPoint(x: CGFloat(index) * 20, y: 50))
        }
        controller.clearAll()
        #expect(controller.document.isEmpty)
        controller.undo()
        #expect(items.count == 3)
    }

    @Test func resetForgetsEverything() {
        controller.chooseTool(.line)
        drag(from: .zero, to: CGPoint(x: 50, y: 0))
        controller.reset()
        #expect(controller.document.isEmpty)
        #expect(!controller.settings.canUndo)
    }
}
