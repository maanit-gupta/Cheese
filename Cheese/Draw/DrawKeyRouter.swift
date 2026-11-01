import Foundation

/// What a key press does while drawing.
enum DrawCommand: Equatable, Sendable {
    case tool(DrawTool)
    case togglePassThrough
    case undo
    case redo
    case snapshot
    case deleteSelection
    case closePopover
    case cancelRadial
    case endTextEditing
    case deselect
    case exit
    case cycleBoard
    case adjustWidth(thicker: Bool)
    /// An index into `CanvasColor.presets`.
    case color(Int)
}

/// Draw mode's keyboard rules, kept apart from AppKit so they can be tested on their own.
///
/// Tools sit on single letters (on by default; Settings can turn them off), ⌘Z / ⇧⌘Z undo and
/// redo, ⇧⌘S takes a snapshot and Esc backs out one step at a time: popover, radial menu, text
/// box, selection, then draw mode itself.
enum DrawKeyRouter {
    struct Modifiers: OptionSet, Sendable {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1 << 0)
        static let control = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    /// What the key means depends on what's going on.
    struct State: Equatable, Sendable {
        var isEditingText = false
        var isPassThrough = false
        var hasSelection = false
        var isRadialOpen = false
        var isPopoverOpen = false
        var usesLetterKeys = true
    }

    static let escapeKeyCode: UInt16 = 53
    /// Delete and Forward Delete.
    static let deleteKeyCodes: Set<UInt16> = [51, 117]

    /// The command for a key, or nil to let the key go on to whoever else wants it.
    static func route(keyCode: UInt16, characters: String, modifiers: Modifiers, state: State) -> DrawCommand? {
        if keyCode == escapeKeyCode {
            if state.isPopoverOpen { return .closePopover }
            if state.isRadialOpen { return .cancelRadial }
            if state.isEditingText { return .endTextEditing }
            if state.hasSelection { return .deselect }
            return .exit
        }
        // Everything else belongs to the text box while one is being edited.
        guard !state.isEditingText else { return nil }

        if modifiers.contains(.command) {
            switch characters.lowercased() {
            case "z": return modifiers.contains(.shift) ? .redo : .undo
            case "s" where modifiers.contains(.shift): return .snapshot
            default: return nil
            }
        }
        guard modifiers.isDisjoint(with: [.control, .option]), characters.count == 1, let character = characters.first else {
            return nil
        }
        // In pass-through the keyboard belongs to the apps underneath; only M comes back.
        if state.isPassThrough {
            guard state.usesLetterKeys, DrawTool.forKey(character) == .passThrough else { return nil }
            return .togglePassThrough
        }
        if deleteKeyCodes.contains(keyCode) {
            return .deleteSelection
        }
        guard state.usesLetterKeys else { return nil }
        if let tool = DrawTool.forKey(character) {
            return tool == .passThrough ? .togglePassThrough : .tool(tool)
        }
        switch character {
        case "b", "B": return .cycleBoard
        case "[": return .adjustWidth(thicker: false)
        case "]": return .adjustWidth(thicker: true)
        case "1"..."9": return character.wholeNumberValue.map { .color($0 - 1) }
        default: return nil
        }
    }
}
