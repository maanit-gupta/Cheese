import CoreGraphics
import Testing
@testable import Cheese

/// Visible frames in Quartz coordinates: a 25 pt menu bar on the primary, a Dock at the bottom of it.
private enum Displays {
    static let primary = CGRect(x: 0, y: 25, width: 1440, height: 805)
    static let right = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
    static let farRight = CGRect(x: 3360, y: 0, width: 1280, height: 800)
    static let left = CGRect(x: -2560, y: -270, width: 2560, height: 1440)
    static let above = CGRect(x: -240, y: -1080, width: 1920, height: 1080)
}

struct SnapLayoutTests {
    @Test func halvesAndMaximizeRespectVisibleFrame() {
        let visible = Displays.primary
        #expect(SnapLayout.frame(for: .leftHalf, in: visible) == CGRect(x: 0, y: 25, width: 720, height: 805))
        #expect(SnapLayout.frame(for: .rightHalf, in: visible) == CGRect(x: 720, y: 25, width: 720, height: 805))
        #expect(SnapLayout.frame(for: .maximize, in: visible) == visible)
        // Quartz y grows downward, so the bottom half has the larger y.
        #expect(SnapLayout.frame(for: .bottomHalf, in: visible) == CGRect(x: 0, y: 427, width: 1440, height: 403))
    }

    @Test func oddWidthsLeaveNoGap() {
        let visible = CGRect(x: 0, y: 0, width: 1367, height: 768)
        let left = SnapLayout.frame(for: .leftHalf, in: visible)
        let right = SnapLayout.frame(for: .rightHalf, in: visible)
        #expect(left.maxX == right.minX)
        #expect(left.width + right.width == 1367)
    }

    @Test func snapsOnTheDisplayHoldingMostOfTheWindow() {
        let window = CGRect(x: 1500, y: 100, width: 800, height: 600)
        let target = SnapLayout.target(for: .leftHalf, windowFrame: window, displays: [Displays.primary, Displays.right])
        #expect(target == SnapTarget(frame: CGRect(x: 1440, y: -180, width: 960, height: 1080), displayIndex: 1))
    }

    @Test func repeatedRightMovesToLeftHalfOfNextDisplay() {
        let displays = [Displays.primary, Displays.right, Displays.farRight]
        let rightHalf = SnapLayout.frame(for: .rightHalf, in: Displays.primary)
        let target = SnapLayout.target(for: .rightHalf, windowFrame: rightHalf, displays: displays)
        #expect(target == SnapTarget(frame: SnapLayout.frame(for: .leftHalf, in: Displays.right), displayIndex: 1))
    }

    @Test func rightFromLeftHalfOfSecondDisplayStaysOnIt() {
        let displays = [Displays.primary, Displays.right]
        let leftHalf = SnapLayout.frame(for: .leftHalf, in: Displays.right)
        let previous = SnapRecord(aimed: leftHalf, result: leftHalf)
        let target = SnapLayout.target(for: .rightHalf, windowFrame: leftHalf, displays: displays, previousSnap: previous)
        #expect(target == SnapTarget(frame: SnapLayout.frame(for: .rightHalf, in: Displays.right), displayIndex: 1))
    }

    @Test func repeatedLeftMirrorsToRightHalfOfDisplayOnTheLeft() {
        let displays = [Displays.primary, Displays.left]
        let leftHalf = SnapLayout.frame(for: .leftHalf, in: Displays.primary)
        let target = SnapLayout.target(for: .leftHalf, windowFrame: leftHalf, displays: displays)
        #expect(target == SnapTarget(frame: SnapLayout.frame(for: .rightHalf, in: Displays.left), displayIndex: 1))
    }

    @Test func lastDisplayDoesNothing() {
        let displays = [Displays.primary, Displays.right]
        let rightHalf = SnapLayout.frame(for: .rightHalf, in: Displays.right)
        #expect(SnapLayout.target(for: .rightHalf, windowFrame: rightHalf, displays: displays) == nil)
        let leftHalf = SnapLayout.frame(for: .leftHalf, in: Displays.primary)
        #expect(SnapLayout.target(for: .leftHalf, windowFrame: leftHalf, displays: displays) == nil)
    }

    @Test func displayAboveIsNotANeighborToTheSide() {
        // The display above is centered over the primary, so it's neither left nor right of it.
        let displays = [Displays.primary, Displays.above]
        #expect(SnapLayout.neighbor(of: 0, towardRight: true, in: displays) == nil)
        #expect(SnapLayout.neighbor(of: 0, towardRight: false, in: displays) == nil)
        // Shifted well left, it becomes the left neighbor.
        let shifted = [Displays.primary, Displays.above.offsetBy(dx: -900, dy: 0)]
        #expect(SnapLayout.neighbor(of: 0, towardRight: false, in: shifted) == 1)
    }

    @Test func nearestNeighborWins() {
        let displays = [Displays.primary, Displays.farRight, Displays.right]
        #expect(SnapLayout.neighbor(of: 0, towardRight: true, in: displays) == 2)
        #expect(SnapLayout.neighbor(of: 2, towardRight: true, in: displays) == 1)
    }

    @Test func stepResizingWindowCountsAsSnappedViaRecord() {
        // Terminal ends up 12 pt shorter than aimed; the record still recognises it.
        let displays = [Displays.primary, Displays.right]
        let aimed = SnapLayout.frame(for: .rightHalf, in: Displays.primary)
        let result = CGRect(x: aimed.minX, y: aimed.minY, width: aimed.width - 5, height: aimed.height - 12)
        let target = SnapLayout.target(
            for: .rightHalf, windowFrame: result, displays: displays,
            previousSnap: SnapRecord(aimed: aimed, result: result)
        )
        #expect(target?.displayIndex == 1)
    }

    @Test func maximizeAndBottomAlwaysStayOnCurrentDisplay() {
        let displays = [Displays.primary, Displays.right]
        let maximized = Displays.primary
        #expect(SnapLayout.target(for: .maximize, windowFrame: maximized, displays: displays)?.frame == maximized)
        let bottom = SnapLayout.frame(for: .bottomHalf, in: Displays.primary)
        #expect(SnapLayout.target(for: .bottomHalf, windowFrame: bottom, displays: displays)?.frame == bottom)
    }

    @Test func clampsWindowsThatWontResize() {
        let visible = Displays.primary
        let rightHalf = SnapLayout.frame(for: .rightHalf, in: visible)
        // Too wide for the half: slides left so it stays on screen.
        #expect(SnapLayout.clampedOrigin(for: CGSize(width: 1000, height: 400), target: rightHalf, visible: visible) == CGPoint(x: 440, y: 25))
        // Smaller than the half: stays at the half's corner.
        #expect(SnapLayout.clampedOrigin(for: CGSize(width: 300, height: 200), target: rightHalf, visible: visible) == CGPoint(x: 720, y: 25))
        // Larger than the display: pinned top-left.
        #expect(SnapLayout.clampedOrigin(for: CGSize(width: 3000, height: 2000), target: rightHalf, visible: visible) == CGPoint(x: 0, y: 25))
    }

    @Test func noDisplaysNoTarget() {
        #expect(SnapLayout.target(for: .maximize, windowFrame: .zero, displays: []) == nil)
    }
}

struct FrameHistoryTests {
    @Test func remembersOnlyTheFirstOriginal() {
        var history = FrameHistory<String>()
        history.rememberOriginal(CGRect(x: 1, y: 1, width: 1, height: 1), for: "a")
        history.rememberOriginal(CGRect(x: 2, y: 2, width: 2, height: 2), for: "a")
        #expect(history.original(for: "a") == CGRect(x: 1, y: 1, width: 1, height: 1))
        #expect(history.original(for: "b") == nil)
    }

    @Test func forgetClearsEverything() {
        var history = FrameHistory<String>()
        history.rememberOriginal(.zero, for: "a")
        history.recordSnap(SnapRecord(aimed: .zero, result: .zero), for: "a")
        history.forget("a")
        #expect(history.original(for: "a") == nil)
        #expect(history.lastSnap(for: "a") == nil)
    }

    @Test func evictsLeastRecentlyUsed() {
        var history = FrameHistory<Int>(capacity: 2)
        history.rememberOriginal(.zero, for: 1)
        history.rememberOriginal(.zero, for: 2)
        history.recordSnap(SnapRecord(aimed: .zero, result: .zero), for: 1)
        history.rememberOriginal(.zero, for: 3)
        #expect(history.original(for: 1) != nil)
        #expect(history.original(for: 2) == nil)
        #expect(history.original(for: 3) != nil)
    }
}

@MainActor
private final class FakeWindows: WindowControlling {
    struct Window: Hashable { var id: Int }

    var focused: Window? = Window(id: 1)
    var frames: [Window: CGRect] = [:]
    var displays = [Displays.primary, Displays.right]
    /// Simulates a fixed-size window: setFrame changes only the origin.
    var fixedSizes: Set<Window> = []

    func focusedWindow() -> Window? { focused }
    func key(for window: Window) -> Window { window }
    func frame(of window: Window) -> CGRect? { frames[window] }
    func visibleFrames() -> [CGRect] { displays }

    func setFrame(_ frame: CGRect, of window: Window) -> CGRect? {
        let size = fixedSizes.contains(window) ? frames[window]?.size ?? frame.size : frame.size
        frames[window] = CGRect(origin: frame.origin, size: size)
        return frames[window]
    }

    func setOrigin(_ origin: CGPoint, of window: Window) -> CGRect? {
        frames[window]?.origin = origin
        return frames[window]
    }
}

@MainActor
struct WindowSnapperTests {
    private let windows = FakeWindows()
    private let window = FakeWindows.Window(id: 1)
    private let original = CGRect(x: 200, y: 200, width: 500, height: 400)

    private func snapper() -> WindowSnapper<FakeWindows> {
        windows.frames[window] = original
        return WindowSnapper(controller: windows)
    }

    @Test func snapThenRestore() {
        let snapper = snapper()
        snapper.perform(.snap(.leftHalf))
        #expect(windows.frames[window] == SnapLayout.frame(for: .leftHalf, in: Displays.primary))
        snapper.perform(.snap(.maximize))
        snapper.perform(.restore)
        #expect(windows.frames[window] == original)
        // Restore with nothing remembered does nothing.
        snapper.perform(.restore)
        #expect(windows.frames[window] == original)
    }

    @Test func rightRightCrossesDisplaysThenStops() {
        let snapper = snapper()
        snapper.perform(.snap(.rightHalf))
        snapper.perform(.snap(.rightHalf))
        #expect(windows.frames[window] == SnapLayout.frame(for: .leftHalf, in: Displays.right))
        snapper.perform(.snap(.rightHalf))
        #expect(windows.frames[window] == SnapLayout.frame(for: .rightHalf, in: Displays.right))
        snapper.perform(.snap(.rightHalf))
        #expect(windows.frames[window] == SnapLayout.frame(for: .rightHalf, in: Displays.right))
        snapper.perform(.restore)
        #expect(windows.frames[window] == original)
    }

    @Test func fixedSizeWindowsAreClampedOnScreen() {
        let snapper = snapper()
        windows.frames[window] = CGRect(x: 100, y: 100, width: 1000, height: 300)
        windows.fixedSizes = [window]
        snapper.perform(.snap(.rightHalf))
        #expect(windows.frames[window] == CGRect(x: 440, y: 25, width: 1000, height: 300))
    }

    @Test func noFocusedWindowIsHarmless() {
        let snapper = snapper()
        windows.focused = nil
        snapper.perform(.snap(.maximize))
        #expect(windows.frames[window] == original)
    }
}
