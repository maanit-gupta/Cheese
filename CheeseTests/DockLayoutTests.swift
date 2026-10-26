import CoreGraphics
import Testing
@testable import Cheese

/// Quartz coordinates: a 1470×956 primary with a 33 pt menu bar, and a display to its right.
struct DockLayoutTests {
    private let primary = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private let right = CGRect(x: 1470, y: -100, width: 1920, height: 1080)
    /// What AppKit reported when the Dock was 70 pt tall at the bottom; may be stale.
    private let cachedWithDock = CGRect(x: 0, y: 33, width: 1470, height: 853)

    private func dock(_ orientation: DockOrientation, _ frame: CGRect?, autohides: Bool = false) -> DockState {
        DockState(orientation: orientation, autohides: autohides, frame: frame)
    }

    @Test func bottomDockReservesItsLiveHeight() {
        // The Dock shrank to 50 pt since AppKit last looked.
        let live = dock(.bottom, CGRect(x: 400, y: 906, width: 670, height: 50))
        #expect(DockLayout.visibleFrame(display: primary, cachedVisible: cachedWithDock, dock: live)
            == CGRect(x: 0, y: 33, width: 1470, height: 873))
    }

    @Test func hiddenDockGivesBackTheWholeBottom() {
        let hidden = dock(.bottom, nil, autohides: true)
        #expect(DockLayout.visibleFrame(display: primary, cachedVisible: cachedWithDock, dock: hidden)
            == CGRect(x: 0, y: 33, width: 1470, height: 923))
        #expect(DockLayout.visibleFrame(display: primary, cachedVisible: cachedWithDock, dock: nil)
            == CGRect(x: 0, y: 33, width: 1470, height: 923))
    }

    @Test func sideDocksReserveTheirWidth() {
        let left = dock(.left, CGRect(x: 0, y: 200, width: 64, height: 500))
        #expect(DockLayout.visibleFrame(display: primary, cachedVisible: cachedWithDock, dock: left)
            == CGRect(x: 64, y: 33, width: 1406, height: 923))
        let rightDock = dock(.right, CGRect(x: 1400, y: 200, width: 70, height: 500))
        #expect(DockLayout.visibleFrame(display: primary, cachedVisible: cachedWithDock, dock: rightDock)
            == CGRect(x: 0, y: 33, width: 1400, height: 923))
    }

    @Test func dockOnAnotherDisplayTakesNothingFromThisOne() {
        let onRight = dock(.bottom, CGRect(x: 2000, y: 910, width: 800, height: 70))
        #expect(DockLayout.visibleFrame(display: primary, cachedVisible: cachedWithDock, dock: onRight)
            == CGRect(x: 0, y: 33, width: 1470, height: 923))
        #expect(DockLayout.visibleFrame(display: right, cachedVisible: right, dock: onRight)
            == CGRect(x: 1470, y: -100, width: 1920, height: 1010))
    }

    @Test func unmeasurableDockFallsBackToAppKit() {
        let unknown = dock(.bottom, nil)
        #expect(DockLayout.visibleFrame(display: primary, cachedVisible: cachedWithDock, dock: unknown) == cachedWithDock)
    }

    @Test func absurdDockNeverTakesMoreThanHalf() {
        let huge = dock(.bottom, CGRect(x: 0, y: 100, width: 1470, height: 856))
        let frame = DockLayout.visibleFrame(display: primary, cachedVisible: cachedWithDock, dock: huge)
        #expect(frame.height == 461.5)
    }
}
