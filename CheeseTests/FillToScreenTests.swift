import CoreGraphics
import Foundation
import Testing
@testable import Cheese

/// Visible frames in Quartz coordinates (top-left origin, y down), menu bar and Dock taken out.
private enum Visible {
    static let primary = CGRect(x: 0, y: 25, width: 1440, height: 805)
    static let right = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
}

struct StageManagerLayoutTests {
    private let on = StageManagerState(isEnabled: true, stripAutoHides: false, dockOrientation: .bottom)

    @Test func stageManagerOffFillsTheWholeVisibleFrame() {
        let layout = StageManagerLayout.layout(mode: .stageManagerSafe, stageManager: .off, configuredInset: 196)
        #expect(layout == .fullVisibleFrame)
        #expect(StageManagerLayout.fillFrame(in: Visible.primary, layout: layout) == Visible.primary)
    }

    @Test func leavesTheStripOnTheLeftByDefault() {
        let layout = StageManagerLayout.layout(mode: .stageManagerSafe, stageManager: on, configuredInset: 196)
        #expect(layout == FillLayout(stripInset: 196, stripEdge: .left))
        #expect(StageManagerLayout.fillFrame(in: Visible.primary, layout: layout) == CGRect(x: 196, y: 25, width: 1244, height: 805))
    }

    @Test func stripMovesRightWhenTheDockIsOnTheLeft() {
        var dockLeft = on
        dockLeft.dockOrientation = .left
        let layout = StageManagerLayout.layout(mode: .stageManagerSafe, stageManager: dockLeft, configuredInset: 200)
        #expect(layout.stripEdge == .right)
        #expect(StageManagerLayout.fillFrame(in: Visible.primary, layout: layout) == CGRect(x: 0, y: 25, width: 1240, height: 805))
        #expect(StageManagerLayout.stripEdge(dock: .right) == .left)
    }

    @Test func hiddenStripOrFullModeLeavesNoRoom() {
        var autoHide = on
        autoHide.stripAutoHides = true
        #expect(StageManagerLayout.layout(mode: .stageManagerSafe, stageManager: autoHide, configuredInset: 196) == .fullVisibleFrame)
        #expect(StageManagerLayout.layout(mode: .fullVisibleFrame, stageManager: on, configuredInset: 196) == .fullVisibleFrame)
    }

    @Test func configuredInsetIsClampedToItsRange() {
        #expect(StageManagerLayout.layout(mode: .stageManagerSafe, stageManager: on, configuredInset: 20).stripInset == 140)
        #expect(StageManagerLayout.layout(mode: .stageManagerSafe, stageManager: on, configuredInset: 900).stripInset == 260)
    }

    @Test func stripNeverTakesMoreThanHalfADisplay() {
        let narrow = CGRect(x: 0, y: 0, width: 300, height: 600)
        let frame = StageManagerLayout.fillFrame(in: narrow, layout: FillLayout(stripInset: 260, stripEdge: .left))
        #expect(frame == CGRect(x: 150, y: 0, width: 150, height: 600))
    }

    @Test func targetsTheDisplayHoldingMostOfTheWindow() {
        let layout = FillLayout(stripInset: 196, stripEdge: .left)
        let window = CGRect(x: 1400, y: 100, width: 800, height: 600)
        let target = StageManagerLayout.target(for: window, displays: [Visible.primary, Visible.right], layout: layout)
        #expect(target?.displayIndex == 1)
        #expect(target?.frame == CGRect(x: 1636, y: -180, width: 1724, height: 1080))
    }

    /// The strip is on a vertical edge, so filling and converting between AppKit and Quartz commute,
    /// on displays above, below and left of the primary too.
    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 1440, height: 875),
        CGRect(x: -240, y: 900, width: 1920, height: 1055),
        CGRect(x: 0, y: -800, width: 1280, height: 800),
        CGRect(x: -2560, y: -270, width: 2560, height: 1415),
    ])
    func fillingCommutesWithDisplayGeometry(_ appKitVisible: CGRect) {
        let primaryHeight: CGFloat = 900
        let layout = FillLayout(stripInset: 196, stripEdge: .left)
        let viaQuartz = StageManagerLayout.fillFrame(
            in: DisplayGeometry.quartzRect(fromAppKit: appKitVisible, primaryDisplayHeight: primaryHeight),
            layout: layout
        )
        let viaAppKit = DisplayGeometry.quartzRect(
            fromAppKit: StageManagerLayout.fillFrame(in: appKitVisible, layout: layout),
            primaryDisplayHeight: primaryHeight
        )
        #expect(viaQuartz == viaAppKit)
        #expect(viaQuartz.minX == appKitVisible.minX + 196)
    }

    @Test func toastSummary() {
        #expect(StageManagerLayout.summary(windows: 11, apps: 7) == "Filled 11 windows across 7 apps")
        #expect(StageManagerLayout.summary(windows: 1, apps: 1) == "Filled 1 window across 1 app")
        #expect(StageManagerLayout.summary(windows: 0, apps: 0) == "No windows to fill")
    }
}

struct StageManagerDetectorTests {
    private func defaults(_ values: [String: Any]) throws -> UserDefaults {
        let suite = "StageManagerDetectorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        return defaults
    }

    @Test func readsStageManagerAndDockPreferences() throws {
        let state = StageManagerDetector.state(
            windowManager: try defaults(["GloballyEnabled": true, "AutoHide": true]),
            dock: try defaults(["orientation": "left"])
        )
        #expect(state == StageManagerState(isEnabled: true, stripAutoHides: true, dockOrientation: .left))
    }

    @Test func missingPreferencesMeanOff() throws {
        #expect(StageManagerDetector.state(windowManager: try defaults([:]), dock: try defaults([:])) == .off)
        #expect(StageManagerDetector.state(windowManager: nil, dock: nil) == .off)
        #expect(StageManagerDetector.state(windowManager: nil, dock: try defaults(["orientation": "sideways"])).dockOrientation == .bottom)
    }

    @Test func preferencesClampTheInsetAndDefaultTheMode() throws {
        let stored = try defaults([PreferenceKey.stageManagerStripInset: 1000.0])
        #expect(Preferences(defaults: stored).stageManagerStripInset == 260)
        #expect(Preferences(defaults: stored).windowFillMode == .stageManagerSafe)
        let full = try defaults([PreferenceKey.windowFillMode: WindowFillMode.fullVisibleFrame.rawValue])
        #expect(Preferences(defaults: full).windowFillMode == .fullVisibleFrame)
        #expect(Preferences(defaults: full).stageManagerStripInset == StageManagerLayout.defaultStripInset)
    }
}

struct BatchFrameHistoryTests {
    @Test func keepsTheFrameFromBeforeTheFirstFill() {
        var history = FrameHistory<String>()
        let before = CGRect(x: 10, y: 10, width: 400, height: 300)
        let filled = CGRect(x: 196, y: 25, width: 1244, height: 805)
        history.rememberBatchOriginals([("a", before)])
        // A second Fill All sees the window already filled; Restore All must still go back to `before`.
        history.rememberBatchOriginals([("a", filled), ("b", before)])
        #expect(history.batchOriginal(for: "a") == before)
        #expect(history.hasBatch)

        let taken = history.takeBatch()
        #expect(taken.map { $0.key } == ["a", "b"])
        #expect(taken.map { $0.frame } == [before, before])
        #expect(!history.hasBatch)
        #expect(history.takeBatch().isEmpty)
    }

    @Test func batchIsSeparateFromSingleWindowRestore() {
        var history = FrameHistory<String>()
        history.rememberOriginal(.zero, for: "a")
        history.rememberBatchOriginals([("a", CGRect(x: 1, y: 1, width: 1, height: 1))])
        _ = history.takeBatch()
        #expect(history.original(for: "a") == .zero)
    }
}

/// Several apps' windows across two displays.
@MainActor
private final class FakeDesktop: WindowControlling {
    struct Window: Hashable {
        var app: pid_t
        var number: Int
    }

    var displays = [Visible.primary, Visible.right]
    var frames: [Window: CGRect] = [:]
    var focused: Window?
    /// Windows whose size can't change, like a fixed-size panel.
    var fixedSizes: Set<Window> = []
    private(set) var setFrameCalls = 0

    func focusedWindow() -> Window? { focused }
    func key(for window: Window) -> Window { window }
    func frame(of window: Window) -> CGRect? { frames[window] }
    func visibleFrames() -> [CGRect] { displays }
    func processID(of window: Window) -> pid_t { window.app }

    func standardWindows() -> [Window] {
        frames.keys.sorted { ($0.app, $0.number) < ($1.app, $1.number) }
    }

    func setFrame(_ frame: CGRect, of window: Window) -> CGRect? {
        setFrameCalls += 1
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
struct FillToScreenTests {
    private let desktop = FakeDesktop()
    private let safari = FakeDesktop.Window(app: 1, number: 1)
    private let safari2 = FakeDesktop.Window(app: 1, number: 2)
    private let notes = FakeDesktop.Window(app: 2, number: 1)
    private let onRight = FakeDesktop.Window(app: 3, number: 1)
    private let layout = FillLayout(stripInset: 196, stripEdge: .left)

    private func snapper() -> WindowSnapper<FakeDesktop> {
        desktop.frames = [
            safari: CGRect(x: 100, y: 100, width: 800, height: 600),
            safari2: CGRect(x: 300, y: 200, width: 600, height: 400),
            notes: CGRect(x: 50, y: 60, width: 300, height: 500),
            onRight: CGRect(x: 1600, y: 0, width: 900, height: 700),
        ]
        return WindowSnapper(controller: desktop) { [layout] in layout }
    }

    @Test func fillsEveryWindowOnItsOwnDisplayAndCountsApps() {
        let snapper = snapper()
        let result = snapper.fillAll()
        #expect(result == BatchWindowFiller<FakeDesktop>.Result(windows: 4, apps: 3))
        let primaryFill = StageManagerLayout.fillFrame(in: Visible.primary, layout: layout)
        #expect(desktop.frames[safari] == primaryFill)
        #expect(desktop.frames[safari2] == primaryFill)
        #expect(desktop.frames[notes] == primaryFill)
        #expect(desktop.frames[onRight] == StageManagerLayout.fillFrame(in: Visible.right, layout: layout))
    }

    @Test func restoreAllPutsEveryWindowBack() {
        let snapper = snapper()
        let before = desktop.frames
        snapper.fillAll()
        snapper.fillAll()
        #expect(snapper.restoreAll() == 4)
        #expect(desktop.frames == before)
        // The batch is used up.
        #expect(snapper.restoreAll() == 0)
    }

    @Test func restoreAllSkipsWindowsClosedSinceTheFill() {
        let snapper = snapper()
        snapper.fillAll()
        desktop.frames[notes] = nil
        #expect(snapper.restoreAll() == 3)
    }

    @Test func alreadyFilledWindowsAreLeftAlone() {
        let snapper = snapper()
        snapper.fillAll()
        let calls = desktop.setFrameCalls
        snapper.fillAll()
        #expect(desktop.setFrameCalls == calls)
    }

    @Test func fixedSizeWindowsStayOnTheirDisplay() {
        let snapper = snapper()
        desktop.fixedSizes = [notes]
        snapper.fillAll()
        let frame = desktop.frames[notes]
        #expect(frame?.size == CGSize(width: 300, height: 500))
        #expect(frame.map { Visible.primary.contains($0) } == true)
    }

    @Test func fillCurrentMovesOnlyTheFocusedWindowAndRestoreUndoesIt() {
        let snapper = snapper()
        let before = desktop.frames
        desktop.focused = safari
        snapper.perform(.fillCurrent)
        #expect(desktop.frames[safari] == StageManagerLayout.fillFrame(in: Visible.primary, layout: layout))
        #expect(desktop.frames[notes] == before[notes])

        snapper.perform(.restore)
        #expect(desktop.frames[safari] == before[safari])
    }
}
