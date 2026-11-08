import CoreGraphics
import Testing
@testable import Cheese

/// Full display frames and visible frames in Quartz coordinates: a 1440×900 primary with a 25 pt
/// menu bar and a 70 pt Dock, and a 1920×1080 display to its right.
private enum Displays {
    static let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    static let primaryVisible = CGRect(x: 0, y: 25, width: 1440, height: 805)
    static let right = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
    static let rightVisible = CGRect(x: 1440, y: -155, width: 1920, height: 1055)
    static let all = [primary, right]
    static let allVisible = [primaryVisible, rightVisible]
}

struct SnapZoneTests {
    @Test func edgesMapToHalvesAndMaximize() {
        let display = Displays.primary
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 0, y: 450), display: display) == .leftHalf)
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 1439, y: 450), display: display) == .rightHalf)
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 720, y: 0), display: display) == .maximize)
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 720, y: 899), display: display) == .bottomHalf)
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 11, y: 450), display: display) == .leftHalf)
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 12, y: 450), display: display) == nil)
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 720, y: 450), display: display) == nil)
    }

    @Test func cornersMapToQuarters() {
        let display = Displays.primary
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 0, y: 0), display: display) == .topLeftQuarter)
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 40, y: 0), display: display) == .topLeftQuarter)
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 0, y: 40), display: display) == .topLeftQuarter)
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 1439, y: 0), display: display) == .topRightQuarter)
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 0, y: 899), display: display) == .bottomLeftQuarter)
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 1439, y: 899), display: display) == .bottomRightQuarter)
        // Just past the corner box along the top edge is maximize again.
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 48, y: 0), display: display) == .maximize)
        // Inside the corner box but away from both edges is nothing.
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 30, y: 30), display: display) == nil)
    }

    @Test func pointerBeyondTheFrameCountsAsTheEdge() {
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 1440, y: 450), display: Displays.primary) == .rightHalf)
        #expect(SnapZoneLayout.zone(at: CGPoint(x: 720, y: 900), display: Displays.primary) == .bottomHalf)
    }

    @Test func sharedEdgesDoNotSnap() {
        // The primary's right edge continues onto the right display, so it's a crossing, not a zone.
        let hit = SnapZoneLayout.hit(at: CGPoint(x: 1439, y: 450), displays: Displays.all, visibleFrames: Displays.allVisible)
        #expect(hit == nil)
        // Same edge seen from the right display's side.
        let crossing = SnapZoneLayout.hit(at: CGPoint(x: 1440, y: 300), displays: Displays.all, visibleFrames: Displays.allVisible)
        #expect(crossing == nil)
        // The right display's own outer edge still snaps, onto its own visible frame.
        let right = SnapZoneLayout.hit(at: CGPoint(x: 3359, y: 300), displays: Displays.all, visibleFrames: Displays.allVisible)
        #expect(right == SnapZoneHit(zone: .rightHalf, frame: CGRect(x: 2400, y: -155, width: 960, height: 1055), displayIndex: 1))
        // The right display's left edge above the primary is open.
        let above = SnapZoneLayout.hit(at: CGPoint(x: 1440, y: -100), displays: Displays.all, visibleFrames: Displays.allVisible)
        #expect(above?.zone == .leftHalf)
    }

    @Test func cornerNextToASharedEdgeStillSnapsFromTheOpenEdge() {
        // Top-right of the primary: its right edge is shared but its top edge is open (the right
        // display sits higher, so above y 0 at x 1439 is nothing).
        let zone = SnapZoneLayout.zone(at: CGPoint(x: 1439, y: 0), display: Displays.primary, others: [Displays.right])
        #expect(zone == .topRightQuarter)
    }

    @Test func framesSplitTheVisibleFrameWithoutGaps() {
        let visible = CGRect(x: 0, y: 25, width: 1441, height: 805)
        let tl = SnapZoneLayout.frame(for: .topLeftQuarter, in: visible)
        let tr = SnapZoneLayout.frame(for: .topRightQuarter, in: visible)
        let bl = SnapZoneLayout.frame(for: .bottomLeftQuarter, in: visible)
        let br = SnapZoneLayout.frame(for: .bottomRightQuarter, in: visible)
        #expect(tl == CGRect(x: 0, y: 25, width: 720, height: 402))
        #expect(tr == CGRect(x: 720, y: 25, width: 721, height: 402))
        #expect(bl == CGRect(x: 0, y: 427, width: 720, height: 403))
        #expect(br == CGRect(x: 720, y: 427, width: 721, height: 403))
        #expect(tl.union(br) == visible)
        #expect(SnapZoneLayout.frame(for: .maximize, in: visible) == visible)
        #expect(SnapZoneLayout.frame(for: .leftHalf, in: visible) == SnapLayout.frame(for: .leftHalf, in: visible))
    }

    @Test func hitUsesTheVisibleFrameOfTheDisplayUnderThePointer() {
        let hit = SnapZoneLayout.hit(at: CGPoint(x: 700, y: 0), displays: Displays.all, visibleFrames: Displays.allVisible)
        #expect(hit == SnapZoneHit(zone: .maximize, frame: Displays.primaryVisible, displayIndex: 0))
        #expect(SnapZoneLayout.hit(at: .zero, displays: Displays.all, visibleFrames: []) == nil)
    }
}

struct WindowDragTrackerTests {
    @Test func windowThatMovesIsADrag() {
        var tracker = WindowDragTracker()
        tracker.mouseDown()
        let r1 = tracker.shouldSample(at: 0)
        #expect(r1)
        tracker.found(windowOrigin: CGPoint(x: 100, y: 100))
        let r2 = tracker.shouldSample(at: 0.02)
        #expect(r2)
        let r3 = tracker.moved(windowOrigin: CGPoint(x: 102, y: 101))
        #expect(!r3)
        let r4 = tracker.shouldSample(at: 0.04)
        #expect(r4)
        let r5 = tracker.moved(windowOrigin: CGPoint(x: 110, y: 100))
        #expect(r5)
        #expect(tracker.isDraggingWindow)
        let r6 = tracker.mouseUp()
        #expect(r6)
        #expect(tracker.phase == .idle)
    }

    @Test func dragInsideAStillWindowIsNot() {
        // Selecting text or moving a slider: the window never moves.
        var tracker = WindowDragTracker()
        tracker.mouseDown()
        _ = tracker.shouldSample(at: 0)
        tracker.found(windowOrigin: CGPoint(x: 100, y: 100))
        for step in 1...30 {
            _ = tracker.shouldSample(at: Double(step) * 0.02)
            let r7 = tracker.moved(windowOrigin: CGPoint(x: 100, y: 100))
            #expect(!r7)
        }
        let r8 = tracker.mouseUp()
        #expect(!r8)
    }

    @Test func noWindowIgnoresTheRestOfTheGesture() {
        var tracker = WindowDragTracker()
        tracker.mouseDown()
        _ = tracker.shouldSample(at: 0)
        tracker.found(windowOrigin: nil)
        #expect(tracker.phase == .ignored)
        let r9 = tracker.shouldSample(at: 1)
        #expect(!r9)
        let r10 = tracker.mouseUp()
        #expect(!r10)
    }

    @Test func windowThatVanishesEndsTheWatch() {
        var tracker = WindowDragTracker()
        tracker.mouseDown()
        tracker.found(windowOrigin: .zero)
        let r11 = tracker.moved(windowOrigin: nil)
        #expect(!r11)
        #expect(tracker.phase == .ignored)
    }

    @Test func samplesAreThrottledToSixtyHertz() {
        var tracker = WindowDragTracker()
        tracker.mouseDown()
        let r12 = tracker.shouldSample(at: 1.000)
        #expect(r12)
        let r13 = tracker.shouldSample(at: 1.005)
        #expect(!r13)
        let r14 = tracker.shouldSample(at: 1.016)
        #expect(!r14)
        let r15 = tracker.shouldSample(at: 1.017)
        #expect(r15)
        let r16 = tracker.shouldSample(at: 1.020)
        #expect(!r16)
    }

    @Test func nothingIsSampledWithoutAButtonDown() {
        var tracker = WindowDragTracker()
        let r17 = tracker.shouldSample(at: 0)
        #expect(!r17)
        tracker.found(windowOrigin: .zero)
        #expect(tracker.phase == .idle)
    }
}
