import Foundation
import os

/// One known global shortcut from macOS or a popular utility, listed in `ReservedShortcuts.json`.
/// `key` is a letter, a digit, a punctuation character, or a key name such as `leftArrow`.
struct ReservedShortcut: Decodable, Equatable, Sendable {
    var key: String
    var modifiers: [String]
    var owner: String
}

/// Shortcuts the hotkey suggester never proposes because other software already uses them.
/// Add entries to `ReservedShortcuts.json`; no code changes needed.
enum ReservedShortcuts {
    private static let family: Set<String> = ["control", "option", "command"]

    static func decode(_ data: Data) throws -> [ReservedShortcut] {
        try JSONDecoder().decode([ReservedShortcut].self, from: data)
    }

    static func bundled(in bundle: Bundle = .main) -> [ReservedShortcut] {
        guard let url = bundle.url(forResource: "ReservedShortcuts", withExtension: "json") else {
            Logger.appHotkeys.error("ReservedShortcuts.json is missing from the bundle")
            return []
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            Logger.appHotkeys.error("Couldn't read ReservedShortcuts.json: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// The letters and digits reserved with exactly Ctrl+Opt+Cmd.
    static func takenCharacters(in entries: [ReservedShortcut]) -> Set<Character> {
        Set(entries.compactMap { entry -> Character? in
            guard Set(entry.modifiers.map { $0.lowercased() }) == family, entry.key.count == 1,
                  let character = entry.key.uppercased().first,
                  character.isASCII, character.isLetter || character.isNumber
            else { return nil }
            return character
        })
    }
}
