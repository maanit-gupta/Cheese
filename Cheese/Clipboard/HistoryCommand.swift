import AppKit
import Carbon.HIToolbox

/// What a key press inside the history panel does.
enum HistoryCommand: Equatable, Sendable {
    case moveUp
    case moveDown
    case paste(plainText: Bool)
    /// Paste the Nth visible item (1-based) immediately.
    case pasteItem(number: Int)
    case togglePin
    case delete
    case close

    private static let digitKeyCodes: [Int] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    /// Maps a key-down to a command. Nil leaves the key to the search field.
    /// Digits use key codes so Cmd+1…9 work on layouts that need Shift for digits.
    init?(keyCode: Int, modifiers: NSEvent.ModifierFlags, charactersIgnoringModifiers: String?) {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])

        switch (keyCode, modifiers) {
        case (kVK_UpArrow, []), (kVK_UpArrow, .shift):
            self = .moveUp
        case (kVK_DownArrow, []), (kVK_DownArrow, .shift):
            self = .moveDown
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
            self = .paste(plainText: false)
        case (kVK_Return, .option), (kVK_ANSI_KeypadEnter, .option):
            self = .paste(plainText: true)
        case (kVK_Escape, []):
            self = .close
        case (kVK_Delete, .command), (kVK_ForwardDelete, .command):
            self = .delete
        case (_, .command):
            if let index = Self.digitKeyCodes.firstIndex(of: keyCode) {
                self = .pasteItem(number: index + 1)
            } else if charactersIgnoringModifiers?.lowercased() == "p" {
                self = .togglePin
            } else {
                return nil
            }
        default:
            return nil
        }
    }
}
