import AppKit
import KeyboardShortcuts
import Testing
@testable import Cheese

struct HotkeyTests {
    private let controlOption: NSEvent.ModifierFlags = [.control, .option]

    @Test func defaultsMatchSpec() {
        let expected: [Hotkey: KeyboardShortcuts.Key] = [
            .openHistory: .v,
            .captureRegion: .four,
            .captureFullScreen: .three,
            .captureWindow: .five,
            .ocrRegion: .t,
            .scrollingCapture: .s,
            .snapLeft: .leftArrow,
            .snapRight: .rightArrow,
            .maximize: .upArrow,
            .snapBottom: .downArrow,
            .restoreWindow: .delete,
        ]
        #expect(expected.count == Hotkey.allCases.count)
        for hotkey in Hotkey.allCases {
            let key = expected[hotkey]
            #expect(key != nil, "No expected default for \(hotkey)")
            if let key {
                #expect(hotkey.name.initialShortcut == .init(key, modifiers: controlOption), "\(hotkey)")
            }
        }
    }

    @Test func defaultsAreUnique() {
        let shortcuts = Hotkey.allCases.compactMap(\.name.initialShortcut)
        #expect(shortcuts.count == Hotkey.allCases.count)
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test func namesAreUniqueAndValid() {
        let names = Hotkey.allCases.map(\.name.rawValue)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.contains(".") })
    }
}
