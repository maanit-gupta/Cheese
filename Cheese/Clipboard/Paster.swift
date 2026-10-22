import AppKit
import Carbon.HIToolbox
import os

/// Writes history items back to the pasteboard and sends Cmd+V to the app they're pasted into.
@MainActor
final class Paster {
    private let pasteboard: NSPasteboard
    private let images: ClipImageStorage

    init(pasteboard: NSPasteboard = .general, images: ClipImageStorage) {
        self.pasteboard = pasteboard
        self.images = images
    }

    /// Puts the item on the pasteboard. Returns the pasteboard's new change count, or nil if nothing was written.
    func write(_ item: ClipItem, plainTextOnly: Bool) async -> Int? {
        switch item.kind {
        case .text, .richText:
            guard let plain = item.plainText else { return nil }
            let stored = plainTextOnly ? [] : item.pasteboardItems
            pasteboard.clearContents()
            if stored.isEmpty {
                pasteboard.setString(plain, forType: .string)
            } else {
                pasteboard.writeObjects(stored.map(Self.pasteboardItem))
            }

        case .image:
            guard let fileName = item.imageFileName else { return nil }
            let data: Data
            do {
                data = try await images.data(for: fileName)
            } catch {
                Logger.clipboard.error("Couldn't read stored image: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)

        case .files:
            let urls = item.fileURLs
            guard !urls.isEmpty else { return nil }
            pasteboard.clearContents()
            if plainTextOnly {
                pasteboard.setString(item.filePaths.joined(separator: "\n"), forType: .string)
            } else {
                pasteboard.writeObjects(urls.map { $0 as NSURL })
            }
        }
        return pasteboard.changeCount
    }

    /// Activates `app`, waits for it to come to the front, then posts Cmd+V. Needs Accessibility.
    func paste(into app: NSRunningApplication) async {
        app.activate()
        for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            try? await Task.sleep(for: .milliseconds(25))
        }
        // Give the app a moment to make its window key after activating.
        try? await Task.sleep(for: .milliseconds(50))
        postCommandV()
    }

    private func postCommandV() {
        let keyCode = KeyboardLayout.keyCode(producing: "v") ?? CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            Logger.clipboard.error("Couldn't create the Cmd+V event")
            return
        }
        // Set the flags explicitly so a still-held Option (from Opt+Return) doesn't turn this into Cmd+Opt+V.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func pasteboardItem(_ content: PasteboardItemContent) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for representation in content.representations {
            item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
        }
        return item
    }
}

/// Finds the key that types a character on the current keyboard layout, so Cmd+V works on Dvorak, AZERTY and so on.
@MainActor
enum KeyboardLayout {
    static func keyCode(producing character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let target = String(character)

        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout,
                    UInt16(code),
                    UInt16(kUCKeyActionDown),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                if status == noErr, String(utf16CodeUnits: characters, count: length) == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
