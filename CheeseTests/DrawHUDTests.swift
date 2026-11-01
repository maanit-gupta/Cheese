import AppKit
import Testing
@testable import Cheese

/// Draw mode's keyboard rules, through the pure router.
struct DrawKeyRouterTests {
    private typealias State = DrawKeyRouter.State

    private func route(_ characters: String, keyCode: UInt16 = 0, _ modifiers: DrawKeyRouter.Modifiers = [], _ state: State = State()) -> DrawCommand? {
        DrawKeyRouter.route(keyCode: keyCode, characters: characters, modifiers: modifiers, state: state)
    }

    private func escape(_ state: State) -> DrawCommand? {
        route("\u{1b}", keyCode: DrawKeyRouter.escapeKeyCode, [], state)
    }

    @Test func lettersPickTheHUDsTools() {
        let expected: [String: DrawCommand] = [
            "p": .tool(.pen), "h": .tool(.highlighter), "e": .tool(.eraser), "i": .tool(.line),
            "a": .tool(.arrow), "r": .tool(.rectangle), "o": .tool(.ellipse), "t": .tool(.text),
            "v": .tool(.select), "m": .togglePassThrough,
        ]
        for (key, command) in expected {
            #expect(route(key) == command)
            #expect(route(key.uppercased(), [.shift]) == command)
        }
    }

    @Test func everyRailToolShowsTheKeyThatPicksIt() {
        for tool in DrawHUD.railGroups.joined() {
            guard let key = tool.key else {
                Issue.record("\(tool) is on the rail without a key")
                continue
            }
            #expect(tool.helpText == "\(tool.title) (\(key))")
            #expect(route(String(key).lowercased()) != nil)
        }
    }

    @Test func escapeBacksOutOneStepAtATime() {
        var state = State(isEditingText: true, hasSelection: true, isRadialOpen: true, isPopoverOpen: true)
        #expect(escape(state) == .closePopover)
        state.isPopoverOpen = false
        #expect(escape(state) == .cancelRadial)
        state.isRadialOpen = false
        #expect(escape(state) == .endTextEditing)
        state.isEditingText = false
        #expect(escape(state) == .deselect)
        state.hasSelection = false
        #expect(escape(state) == .exit)
    }

    @Test func commandShortcuts() {
        #expect(route("z", [.command]) == .undo)
        #expect(route("Z", [.command, .shift]) == .redo)
        #expect(route("S", [.command, .shift]) == .snapshot)
        #expect(route("s", [.command]) == nil)
        #expect(route("q", [.command]) == nil)
    }

    @Test func textBeingEditedKeepsItsKeys() {
        let state = State(isEditingText: true)
        #expect(route("p", [], state) == nil)
        #expect(route("z", [.command], state) == nil)
        #expect(route("\u{7f}", keyCode: 51, [], state) == nil)
    }

    @Test func passThroughOnlyComesBackWithM() {
        let state = State(isPassThrough: true)
        #expect(route("m", [], state) == .togglePassThrough)
        #expect(route("p", [], state) == nil)
        #expect(route("\u{7f}", keyCode: 51, [], state) == nil)
    }

    @Test func lettersOffLeavesTheMouseAndShortcuts() {
        let state = State(usesLetterKeys: false)
        #expect(route("p", [], state) == nil)
        #expect(route("5", [], state) == nil)
        #expect(route("z", [.command], state) == .undo)
        #expect(route("\u{7f}", keyCode: 51, [], state) == .deleteSelection)
        #expect(escape(state) == .exit)
    }

    @Test func digitsBracketsAndBoards() {
        #expect(route("1") == .color(0))
        #expect(route("9") == .color(8))
        #expect(route("0") == nil)
        #expect(route("[") == .adjustWidth(thicker: false))
        #expect(route("]") == .adjustWidth(thicker: true))
        #expect(route("b") == .cycleBoard)
    }

    @Test func otherModifiersLetKeysThrough() {
        #expect(route("p", [.control]) == nil)
        #expect(route("p", [.option]) == nil)
        #expect(route("q") == nil)
    }
}

/// Where draw mode's windows sit relative to everything else Cheese opens.
@MainActor
struct DrawLayeringTests {
    @Test func thePaletteSitsAboveTheHUDWhichSitsAboveTheCanvas() {
        #expect(DrawLevels.canvas.rawValue > NSWindow.Level.floating.rawValue)
        #expect(DrawLevels.hud.rawValue > DrawLevels.canvas.rawValue)
        #expect(DrawLevels.panels.rawValue > DrawLevels.hud.rawValue)
        // The palette is a CheesePanel at the default level.
        #expect(CheesePanel.Behavior().level == DrawLevels.panels)
    }

    @Test func overlaysUseTheCanvasLevel() throws {
        let screen = try #require(NSScreen.screens.first)
        let window = DrawOverlayWindow(screen: screen, displayID: 1)
        defer { window.close() }
        #expect(window.level == DrawLevels.canvas)
    }
}

/// Picking tools never opens a popover, and Esc backs out of a selection before leaving.
@MainActor
struct DrawHUDBehaviorTests {
    private let page: CanvasPageID = 5
    private let controller = DrawModeController(services: DrawModeController.Services(
        captureDisplay: { _, _ in throw CaptureError.displayNotFound },
        openEditor: { _ in },
        isScreenRecordingGranted: { false },
        explainMissingScreenRecording: { _ in },
        usesLetterKeys: { true }
    ))

    private func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) ?? NSEvent()
    }

    private func key(_ characters: String, keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) ?? NSEvent()
    }

    @Test func switchingToolsNeverOpensAPopover() {
        for tool in DrawTool.allCases {
            controller.chooseTool(tool)
            #expect(controller.settings.openPopover == nil)
        }
        for letter in ["p", "h", "e", "i", "a", "r", "o", "t", "v"] {
            #expect(controller.handleKeyDown(key(letter)))
            #expect(controller.settings.openPopover == nil)
        }
    }

    @Test func escapeDeselectsBeforeLeaving() {
        controller.chooseTool(.rectangle)
        controller.mouseDown(on: page, at: CGPoint(x: 10, y: 10), event: event(.leftMouseDown))
        controller.mouseDragged(on: page, at: CGPoint(x: 80, y: 60), event: event(.leftMouseDragged))
        controller.mouseUp(on: page, at: CGPoint(x: 80, y: 60), event: event(.leftMouseUp))
        controller.chooseTool(.select)
        controller.mouseDown(on: page, at: CGPoint(x: 10, y: 35), event: event(.leftMouseDown))
        controller.mouseUp(on: page, at: CGPoint(x: 10, y: 35), event: event(.leftMouseUp))
        #expect(controller.renderState(for: page).selectedBounds.count == 1)

        #expect(controller.handleKeyDown(key("\u{1b}", keyCode: DrawKeyRouter.escapeKeyCode)))
        #expect(controller.renderState(for: page).selectedBounds.isEmpty)
    }

    @Test func clicksDrawWhenNothingElseHasTheKeyboard() {
        #expect(!controller.isYielded)
        #expect(controller.shouldDrawOnCanvasClick())
    }
}
