import AppKit
import CoreGraphics
import os

/// Stops every keyboard, pointer, scroll and gesture event from reaching macOS, so the screen and
/// keyboard can be wiped.
@MainActor
protocol InputBlocking: AnyObject {
    /// Esc went down (true) or up (false) while blocked. Key repeats count as down.
    var onEscape: ((Bool) -> Void)? { get set }
    /// Starts blocking. False when the system refused (no Accessibility).
    func block() -> Bool
    func unblock()
}

/// An event tap at the HID level that swallows everything. The tap belongs to the process, so if
/// Cheese quits or crashes, input comes back at once.
@MainActor
final class EventTapInputBlocker: InputBlocking {
    var onEscape: ((Bool) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detachedCursor = false

    private static let escapeKeyCode: Int64 = 53

    var isBlocking: Bool { tap != nil }

    func block() -> Bool {
        guard tap == nil else { return true }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Every event type: keys, modifiers, media and brightness keys (system-defined), clicks,
        // movement, scrolling and trackpad gestures.
        let everything = CGEventMask.max
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: everything,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let swallow = MainActor.assumeIsolated {
                    Unmanaged<EventTapInputBlocker>.fromOpaque(refcon).takeUnretainedValue()
                        .handle(type, keyCode: keyCode)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Logger.sweep.error("Couldn't create the input event tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        // Keeps the pointer still even for movement that reaches the window server first.
        detachedCursor = CGAssociateMouseAndMouseCursorPosition(0) == .success
        Logger.sweep.notice("Keyboard and trackpad locked")
        return true
    }

    func unblock() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        if detachedCursor {
            CGAssociateMouseAndMouseCursorPosition(1)
            detachedCursor = false
        }
        Logger.sweep.notice("Keyboard and trackpad unlocked")
    }

    /// Whether to swallow the event. Everything is swallowed; Esc is reported on the way.
    private func handle(_ type: CGEventType, keyCode: Int64) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it's ever slow; switch it straight back on.
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        case .keyDown where keyCode == Self.escapeKeyCode:
            onEscape?(true)
        case .keyUp where keyCode == Self.escapeKeyCode:
            onEscape?(false)
        default:
            break
        }
        return true
    }
}
