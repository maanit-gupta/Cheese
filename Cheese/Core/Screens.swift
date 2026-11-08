import AppKit

/// `NSScreen` helpers built on `DisplayGeometry`.
@MainActor
enum Screens {
    static var primaryDisplayHeight: CGFloat {
        DisplayGeometry.primaryDisplayHeight(appKitFrames: NSScreen.screens.map(\.frame))
    }

    /// The display under the mouse pointer.
    static var underMouse: NSScreen? {
        let screens = NSScreen.screens
        let index = DisplayGeometry.indexOfDisplay(containing: NSEvent.mouseLocation, frames: screens.map(\.frame))
        return index.map { screens[$0] } ?? NSScreen.main
    }

    static func screen(withDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    static func quartzRect(fromAppKit rect: CGRect) -> CGRect {
        DisplayGeometry.quartzRect(fromAppKit: rect, primaryDisplayHeight: primaryDisplayHeight)
    }

    static func appKitRect(fromQuartz rect: CGRect) -> CGRect {
        DisplayGeometry.appKitRect(fromQuartz: rect, primaryDisplayHeight: primaryDisplayHeight)
    }

    static func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        DisplayGeometry.quartzPoint(fromAppKit: point, primaryDisplayHeight: primaryDisplayHeight)
    }

    static func appKitPoint(fromQuartz point: CGPoint) -> CGPoint {
        DisplayGeometry.appKitPoint(fromQuartz: point, primaryDisplayHeight: primaryDisplayHeight)
    }

    /// The pointer in Quartz (top-left origin) coordinates, the space AX window frames use.
    static var mouseLocationQuartz: CGPoint {
        quartzPoint(fromAppKit: NSEvent.mouseLocation)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
