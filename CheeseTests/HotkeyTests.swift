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
            .drawOnScreen: .d,
            .commandPalette: .return,
            .toggleShelf: .f,
            .autoKill: .q,
            .killAllApps: .q,
        ]
        // The instant variants are their panel's shortcut plus Shift.
        let withShift: Set<Hotkey> = [.killAllApps]
        // Share has no default shortcut; the user can assign one.
        let unbound: Set<Hotkey> = [.showShare]
        #expect(unbound.allSatisfy { $0.name.initialShortcut == nil })
        #expect(expected.count + unbound.count == Hotkey.allCases.count)
        for hotkey in Hotkey.allCases where !unbound.contains(hotkey) {
            let key = expected[hotkey]
            #expect(key != nil, "No expected default for \(hotkey)")
            if let key {
                let modifiers = withShift.contains(hotkey) ? controlOption.union(.shift) : controlOption
                #expect(hotkey.name.initialShortcut == .init(key, modifiers: modifiers), "\(hotkey)")
            }
        }
    }

    @Test func defaultsAreUnique() {
        let shortcuts = Hotkey.allCases.compactMap(\.name.initialShortcut)
        #expect(shortcuts.count == Hotkey.allCases.count - 1)
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test func namesAreUniqueAndValid() {
        let names = Hotkey.allCases.map(\.name.rawValue)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.contains(".") })
    }
}
