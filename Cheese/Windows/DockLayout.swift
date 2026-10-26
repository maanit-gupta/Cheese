import CoreGraphics

/// The Dock as it is right now, read fresh before every snap or fill.
struct DockState: Equatable, Sendable {
    var orientation: DockOrientation
    /// "Automatically hide and show the Dock" is on, so the Dock takes no room from windows.
    var autohides: Bool
    /// The Dock's tiles in Quartz coordinates, or nil when Accessibility couldn't measure it.
    var frame: CGRect?
}

/// Where windows may go on a display, measured against the live Dock instead of AppKit's
/// `NSScreen.visibleFrame`. A menu bar app's `visibleFrame` can lag behind the Dock: after the Dock
/// is hidden, resized or moved to another display it keeps the old reservation, and fills and
/// snaps leave a gap where the Dock used to be (or slide under where it is now).
///
/// Quartz coordinates throughout (top-left origin, y down), like `SnapLayout`.
enum DockLayout {
    /// The display less its menu bar and, if the Dock is on this display and showing, the Dock.
    ///
    /// - Parameters:
    ///   - display: the display's full frame.
    ///   - cachedVisible: AppKit's `visibleFrame`. Only its top edge (the menu bar) is trusted, unless
    ///     the Dock couldn't be measured, in which case it's returned as is.
    ///   - dock: the live Dock, or nil when it isn't running.
    static func visibleFrame(display: CGRect, cachedVisible: CGRect, dock: DockState?) -> CGRect {
        let display = display.standardized
        let cachedVisible = cachedVisible.standardized
        // The menu bar sits at the top; never let a stale or odd value push past half the display.
        let menuBar = min(max(cachedVisible.minY - display.minY, 0), display.height / 2)
        let area = CGRect(x: display.minX, y: display.minY + menuBar, width: display.width, height: display.height - menuBar)

        guard let dock, !dock.autohides else { return area }
        guard let dockFrame = dock.frame?.standardized, !dockFrame.isEmpty else { return cachedVisible }
        guard display.contains(CGPoint(x: dockFrame.midX, y: dockFrame.midY)) else { return area }

        switch dock.orientation {
        case .bottom:
            let reserved = min(max(display.maxY - dockFrame.minY, 0), area.height / 2)
            return CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height - reserved)
        case .left:
            let reserved = min(max(dockFrame.maxX - display.minX, 0), area.width / 2)
            return CGRect(x: area.minX + reserved, y: area.minY, width: area.width - reserved, height: area.height)
        case .right:
            let reserved = min(max(display.maxX - dockFrame.minX, 0), area.width / 2)
            return CGRect(x: area.minX, y: area.minY, width: area.width - reserved, height: area.height)
        }
    }
}
