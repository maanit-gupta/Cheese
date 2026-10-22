import AppKit
import ApplicationServices
import os

/// The focused window of another app, through Accessibility.
struct AXWindow {
    var app: AXUIElement
    var element: AXUIElement
    var pid: pid_t
}

/// Identifies a window across snaps: the owning process plus the AX element (compared with `CFEqual`).
struct AXWindowKey: Hashable {
    var pid: pid_t
    var element: AXUIElement
}

/// `WindowControlling` over the Accessibility API.
@MainActor
final class WindowManager: WindowControlling {
    func focusedWindow() -> AXWindow? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = front.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        guard let element = elementAttribute(kAXFocusedWindowAttribute, of: app) else { return nil }
        // Leave native full-screen and minimized windows alone.
        if boolAttribute("AXFullScreen", of: element) == true || boolAttribute(kAXMinimizedAttribute, of: element) == true {
            return nil
        }
        return AXWindow(app: app, element: element, pid: pid)
    }

    func key(for window: AXWindow) -> AXWindowKey {
        AXWindowKey(pid: window.pid, element: window.element)
    }

    func frame(of window: AXWindow) -> CGRect? {
        guard let origin = pointAttribute(kAXPositionAttribute, of: window.element),
              let size = sizeAttribute(kAXSizeAttribute, of: window.element)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func setFrame(_ frame: CGRect, of window: AXWindow) -> CGRect? {
        withoutEnhancedUserInterface(window.app) {
            // Size, move, size again: a window can't grow past the display it's currently on,
            // so a move between displays of different sizes needs the second resize.
            if isSettable(kAXSizeAttribute, of: window.element) {
                setSize(frame.size, of: window.element)
            }
            setPosition(frame.origin, of: window.element)
            if isSettable(kAXSizeAttribute, of: window.element) {
                setSize(frame.size, of: window.element)
            }
        }
        return self.frame(of: window)
    }

    func setOrigin(_ origin: CGPoint, of window: AXWindow) -> CGRect? {
        withoutEnhancedUserInterface(window.app) {
            setPosition(origin, of: window.element)
        }
        return frame(of: window)
    }

    func visibleFrames() -> [CGRect] {
        NSScreen.screens.map { Screens.quartzRect(fromAppKit: $0.visibleFrame) }
    }

    func standardWindows() -> [AXWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ownPID }
            .flatMap { app -> [AXWindow] in
                let pid = app.processIdentifier
                let appElement = AXUIElementCreateApplication(pid)
                // A hung app shouldn't stall the whole fill.
                AXUIElementSetMessagingTimeout(appElement, Self.batchMessagingTimeout)
                guard let value = copyAttribute(kAXWindowsAttribute, of: appElement),
                      CFGetTypeID(value) == CFArrayGetTypeID(),
                      let windows = value as? [AXUIElement]
                else { return [] }
                return windows.compactMap { element in
                    AXUIElementSetMessagingTimeout(element, Self.batchMessagingTimeout)
                    return isFillable(element) ? AXWindow(app: appElement, element: element, pid: pid) : nil
                }
            }
    }

    func processID(of window: AXWindow) -> pid_t {
        window.pid
    }

    /// Seconds to wait on each app during a batch fill, instead of the system's default of about six.
    private static let batchMessagingTimeout: Float = 0.5

    /// An ordinary document window that can be resized: not a panel, sheet or dialog, and not
    /// minimized or in native full screen.
    private func isFillable(_ element: AXUIElement) -> Bool {
        stringAttribute(kAXRoleAttribute, of: element) == kAXWindowRole
            && stringAttribute(kAXSubroleAttribute, of: element) == kAXStandardWindowSubrole
            && boolAttribute(kAXMinimizedAttribute, of: element) != true
            && boolAttribute("AXFullScreen", of: element) != true
            && isSettable(kAXSizeAttribute, of: element)
    }

    // MARK: AX helpers

    /// Apps with "enhanced user interface" on (set by assistive tools) animate every frame change,
    /// which makes snapping slow and inexact. Turn it off for the move and restore it afterwards.
    private func withoutEnhancedUserInterface(_ app: AXUIElement, _ body: () -> Void) {
        let attribute = "AXEnhancedUserInterface"
        let wasEnabled = boolAttribute(attribute, of: app) == true
        if wasEnabled {
            AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanFalse)
        }
        body()
        if wasEnabled {
            AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
        }
    }

    private func copyAttribute(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            if error != .noValue, error != .attributeUnsupported {
                Logger.windows.debug("Reading \(attribute, privacy: .public) failed: \(error.rawValue)")
            }
            return nil
        }
        return value
    }

    private func elementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        copyAttribute(attribute, of: element) as? String
    }

    private func boolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        guard let value = copyAttribute(attribute, of: element), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    private func axValue(_ attribute: String, of element: AXUIElement, type: AXValueType) -> AXValue? {
        guard let value = copyAttribute(attribute, of: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        return AXValueGetType(axValue) == type ? axValue : nil
    }

    private func pointAttribute(_ attribute: String, of element: AXUIElement) -> CGPoint? {
        guard let value = axValue(attribute, of: element, type: .cgPoint) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(_ attribute: String, of element: AXUIElement) -> CGSize? {
        guard let value = axValue(attribute, of: element, type: .cgSize) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func isSettable(_ attribute: String, of element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private func setPosition(_ origin: CGPoint, of element: AXUIElement) {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        let error = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        if error != .success {
            Logger.windows.error("Moving the window failed: \(error.rawValue)")
        }
    }

    private func setSize(_ size: CGSize, of element: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        let error = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        if error != .success {
            Logger.windows.error("Resizing the window failed: \(error.rawValue)")
        }
    }
}
