import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

/// The `Ctrl+Opt+Cmd+<letter or digit>` family app hotkeys live in, and conversions between
/// shortcuts and the single characters `HotkeySuggester` works with.
enum AppHotkeyKeys {
    static let modifiers: NSEvent.ModifierFlags = [.control, .option, .command]
    private static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    private static let keys: [Character: KeyboardShortcuts.Key] = [
        "A": .a, "B": .b, "C": .c, "D": .d, "E": .e, "F": .f, "G": .g, "H": .h, "I": .i, "J": .j,
        "K": .k, "L": .l, "M": .m, "N": .n, "O": .o, "P": .p, "Q": .q, "R": .r, "S": .s, "T": .t,
        "U": .u, "V": .v, "W": .w, "X": .x, "Y": .y, "Z": .z,
        "0": .zero, "1": .one, "2": .two, "3": .three, "4": .four,
        "5": .five, "6": .six, "7": .seven, "8": .eight, "9": .nine,
    ]
    private static let characters = Dictionary(uniqueKeysWithValues: keys.map { ($0.value, $0.key) })

    static func shortcut(for character: Character) -> KeyboardShortcuts.Shortcut? {
        keys[character].map { KeyboardShortcuts.Shortcut($0, modifiers: modifiers) }
    }

    /// The letter or digit of a shortcut in the family; nil for any other shortcut.
    static func character(of shortcut: KeyboardShortcuts.Shortcut) -> Character? {
        guard shortcut.modifiers.intersection(relevantModifiers) == modifiers, let key = shortcut.key else { return nil }
        return characters[key]
    }

    static func takenCharacters(in shortcuts: [KeyboardShortcuts.Shortcut]) -> Set<Character> {
        Set(shortcuts.compactMap(character(of:)))
    }
}

/// macOS's own keyboard shortcuts (System Settings → Keyboard → Keyboard Shortcuts) that are switched on.
enum SystemShortcutReader {
    static func enabledShortcuts() -> [KeyboardShortcuts.Shortcut] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers] as? Int
            else { return nil }
            return KeyboardShortcuts.Shortcut(carbonKeyCode: code, carbonModifiers: modifiers)
        }
    }
}
