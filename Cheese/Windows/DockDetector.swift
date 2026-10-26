import AppKit
import ApplicationServices

/// Reads the Dock's current position, size and auto-hide setting: preferences straight from
/// `cfprefsd` (synchronized, so a change in System Settings is seen at once) and the Dock's frame
/// from its Accessibility tree.
enum DockDetector {
    static let bundleID = "com.apple.dock"

    @MainActor
    static func current() -> DockState? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let domain = bundleID as CFString
        CFPreferencesAppSynchronize(domain)
        let autohides = CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool ?? false
        let orientation = (CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String)
            .flatMap(DockOrientation.init(rawValue:)) ?? .bottom
        return DockState(orientation: orientation, autohides: autohides, frame: autohides ? nil : tilesFrame(pid: dock.processIdentifier))
    }

    /// The frame of the Dock's tile list (its first `AXList` child), in Quartz coordinates.
    private static func tilesFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement]
        else { return nil }
        for element in elements {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXListRole else { continue }
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
            else { return nil }
            var origin = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
                  AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
            else { return nil }
            return CGRect(origin: origin, size: extent)
        }
        return nil
    }
}
