import CoreGraphics
import Foundation
import Testing
@testable import Cheese

@MainActor
final class FakeFocusSwitcher: FocusSwitching {
    var onResult = FocusSwitchResult.on(focusWasAlreadyOn: false)
    var missing: [String] = []
    private(set) var onCount = 0
    private(set) var offCount = 0
    private(set) var offNowCount = 0

    func turnOn() async -> FocusSwitchResult {
        onCount += 1
        return onResult
    }

    func turnOff() async -> Bool {
        offCount += 1
        return true
    }

    func turnOffNow() {
        offNowCount += 1
    }

    func missingShortcuts() async -> [String] {
        missing
    }
}

@MainActor
final class FakeShareDetector: ShareDetecting {
    var source: ShareSource?

    func detect() -> ShareSource? {
        source
    }
}

struct HushPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func manualHushLastsItsLength() {
        var policy = HushPolicy()
        policy.manual = ManualHush(duration: .preset(.thirtyMinutes), startedAt: start)
        #expect(policy.shouldHush(at: start + 60))
        #expect(policy.indicatorText(at: start + 60) == "29m")
        #expect(!policy.shouldHush(at: start + 30 * 60))
    }

    @Test func indefiniteHushHasNoCountdown() {
        var policy = HushPolicy()
        policy.manual = ManualHush(duration: .indefinitely, startedAt: start)
        #expect(policy.shouldHush(at: start + 100_000))
        #expect(policy.indicatorText(at: start) == nil)
    }

    @Test func sharingHushesAndGraceKeepsItThirtySeconds() {
        var policy = HushPolicy()
        policy.observe(.app("Zoom"), at: start)
        #expect(policy.reason(at: start) == .sharing(.app("Zoom")))
        policy.observe(nil, at: start + 10)
        #expect(policy.reason(at: start + 10) == .grace(until: start + 30))
        #expect(policy.shouldHush(at: start + 29))
        #expect(!policy.shouldHush(at: start + 30))
    }

    @Test func automaticOffIgnoresSharing() {
        var policy = HushPolicy()
        policy.automatic = false
        policy.observe(.mirroring, at: start)
        #expect(!policy.shouldHush(at: start))
    }

    @Test func manualThatEndsWhileSharingHandsOverToSharing() {
        var policy = HushPolicy()
        policy.manual = ManualHush(duration: .preset(.thirtyMinutes), startedAt: start)
        policy.observe(.remote, at: start + 30 * 60)
        #expect(policy.reason(at: start + 30 * 60) == .sharing(.remote))
    }

    @Test func turningOffDuringAShareSnoozesUntilItEnds() {
        var policy = HushPolicy()
        policy.observe(.app("Teams"), at: start)
        policy.turnOff(at: start + 5)
        #expect(!policy.shouldHush(at: start + 5))
        policy.observe(.app("Teams"), at: start + 10)
        #expect(!policy.shouldHush(at: start + 10))
        // The share ends, and its grace runs out: the next share hushes again.
        policy.observe(nil, at: start + 20)
        policy.observe(nil, at: start + 41)
        policy.observe(.app("Teams"), at: start + 60)
        #expect(policy.shouldHush(at: start + 60))
    }

    @Test func turnOffEndsAManualHush() {
        var policy = HushPolicy()
        policy.manual = ManualHush(duration: .indefinitely, startedAt: start)
        policy.turnOff(at: start + 5)
        #expect(policy.manual == nil)
        #expect(!policy.snoozedUntilSharingEnds)
    }
}

struct ShareSignalsTests {
    private let signals = ShareSignals(rules: ShareSignals.bundledRules())

    private func window(_ bundleID: String, _ name: String, height: CGFloat = 40, pid: Int32 = 10) -> WindowSnapshot {
        WindowSnapshot(
            ownerBundleID: bundleID, ownerName: "", name: name, layer: 0,
            bounds: CGRect(x: 0, y: 0, width: 400, height: height), pid: pid
        )
    }

    private func source(_ windows: [WindowSnapshot], mirroring: Bool = false, remote: Bool = false) -> ShareSource? {
        signals.source(windows: windows, mirroring: mirroring, remoteSession: remote, excludingPID: 1)
    }

    @Test func bundledRulesLoad() {
        #expect(signals.rules.count >= 8)
        #expect(signals.rules.allSatisfy { !$0.bundleIDs.isEmpty && !$0.nameContains.isEmpty })
    }

    @Test(arguments: [
        ("us.zoom.xos", "zoom share toolbar window", "Zoom"),
        ("us.zoom.xos", "Zoom Share Statusbar Window", "Zoom"),
        ("com.microsoft.teams2", "Sharing control bar | Microsoft Teams", "Microsoft Teams"),
        ("com.tinyspeck.slackmacgap", "Slack | Screen share", "Slack"),
        ("com.google.Chrome", "meet.google.com is sharing your screen.", "Google Meet"),
        ("com.brave.Browser", "zoom.us is sharing a window.", "Google Meet"),
        ("org.mozilla.firefox", "Firefox — Sharing Indicator", "Firefox"),
        ("com.apple.controlcenter", "Screen Recording", "Another app"),
    ])
    func recognizesShareIndicators(_ bundleID: String, _ name: String, _ app: String) {
        #expect(source([window(bundleID, name)]) == .app(app))
    }

    @Test func ordinaryWindowsDontCount() {
        #expect(source([
            window("us.zoom.xos", "Zoom Meeting", height: 800),
            window("com.google.Chrome", "Inbox - Gmail"),
            window("com.tinyspeck.slackmacgap", "general - Acme"),
        ]) == nil)
    }

    @Test func aBrowserTabTitledLikeAnIndicatorDoesntCount() {
        #expect(source([window("com.google.Chrome", "Bob is sharing your screen - Docs", height: 900)]) == nil)
    }

    @Test func unknownAppsAndCheesesOwnWindowsDontCount() {
        #expect(source([window("com.example.notes", "screen share")]) == nil)
        #expect(source([window("us.zoom.xos", "zoom share toolbar window", pid: 1)]) == nil)
        #expect(source([window("us.zoom.xos", "")]) == nil)
    }

    @Test func remoteThenMirroringComeFirst() {
        let zoom = window("us.zoom.xos", "zoom share toolbar window")
        #expect(source([zoom], mirroring: true, remote: true) == .remote)
        #expect(source([zoom], mirroring: true) == .mirroring)
        #expect(source([], mirroring: true) == .mirroring)
    }
}

struct HushShortcutsTests {
    @Test func findsMissingShortcuts() {
        #expect(HushShortcuts.missing(fromList: "DND\nCheese Hush On\nCheese Hush Off\n").isEmpty)
        #expect(HushShortcuts.missing(fromList: "Cheese Hush On\n") == ["Cheese Hush Off"])
        #expect(HushShortcuts.missing(fromList: "") == HushShortcuts.all)
    }

    @Test func readsWhetherAFocusWasAlreadyOn() {
        #expect(!HushShortcuts.focusWasAlreadyOn(output: nil))
        #expect(!HushShortcuts.focusWasAlreadyOn(output: "  \n"))
        #expect(HushShortcuts.focusWasAlreadyOn(output: "Work\n"))
        #expect(HushShortcuts.focusWasAlreadyOn(output: "Do Not Disturb"))
    }
}

@MainActor
struct HushControllerTests {
    let clock = FakeClock()
    let switcher = FakeFocusSwitcher()
    let detector = FakeShareDetector()
    let defaults: UserDefaults
    let toasts = Toasts()
    let controller: HushController

    final class Toasts {
        var messages: [String] = []
    }

    init() {
        let suite = "HushTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let clock = clock
        let toasts = toasts
        controller = HushController(
            switcher: switcher, detector: detector, defaults: defaults,
            now: { clock.now },
            showToast: { message, _, _ in toasts.messages.append(message) },
            pollInterval: .seconds(3600)
        )
    }

    /// Lets the switch to Focus finish.
    private func settle() async {
        for _ in 0..<200 where controller.isSwitching {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func sharingTurnsFocusOnOnceAndOffAfterTheGrace() async {
        controller.start()
        await settle()
        #expect(switcher.onCount == 0)

        detector.source = .app("Zoom")
        controller.poll()
        await settle()
        controller.poll()
        await settle()
        #expect(switcher.onCount == 1)
        #expect(controller.isEngaged)
        #expect(defaults.bool(forKey: PreferenceKey.hushEngagedByCheese))

        detector.source = nil
        clock.advance(10)
        controller.poll()
        await settle()
        #expect(controller.isEngaged)
        clock.advance(25)
        controller.poll()
        await settle()
        #expect(!controller.isEngaged)
        #expect(switcher.offCount == 1)
        #expect(!defaults.bool(forKey: PreferenceKey.hushEngagedByCheese))
        // Automatic Hush never shows toasts: they'd be on the shared screen.
        #expect(toasts.messages.isEmpty)
    }

    @Test func aFocusThatWasAlreadyOnIsLeftOn() async {
        switcher.onResult = .on(focusWasAlreadyOn: true)
        controller.start()
        controller.hush(.indefinitely)
        await settle()
        #expect(controller.isEngaged)
        #expect(!defaults.bool(forKey: PreferenceKey.hushEngagedByCheese))
        controller.turnOff()
        await settle()
        #expect(!controller.isEngaged)
        #expect(switcher.offCount == 0)
    }

    @Test func manualHushEndsOnTime() async {
        controller.start()
        controller.hush(.preset(.thirtyMinutes))
        await settle()
        #expect(controller.isEngaged)
        #expect(controller.indicatorText == "30m")
        clock.advance(30 * 60)
        controller.poll()
        await settle()
        #expect(!controller.isEngaged)
        #expect(controller.manual == nil)
    }

    @Test func cheesesOwnRecordingCounts() async {
        controller.start()
        controller.setCheeseRecording(true)
        await settle()
        #expect(controller.isEngaged)
        #expect(controller.reason == .sharing(.cheeseRecording))
    }

    @Test func missingShortcutsOnAManualHushSayWhatToDo() async {
        switcher.onResult = .failed("The “Cheese Hush On” shortcut didn't run.")
        controller.start()
        controller.hush(.indefinitely)
        await settle()
        #expect(!controller.isEngaged)
        #expect(controller.manual == nil)
        #expect(toasts.messages == ["Set up Hush first"])
        #expect(controller.statusText == "Hush isn't set up")
    }

    @Test func failedAutomaticHushWaitsBeforeTryingAgain() async {
        switcher.onResult = .failed("nope")
        controller.start()
        detector.source = .mirroring
        controller.poll()
        await settle()
        controller.poll()
        await settle()
        #expect(switcher.onCount == 1)
        clock.advance(HushController.retryDelay)
        controller.poll()
        await settle()
        #expect(switcher.onCount == 2)
        #expect(toasts.messages.isEmpty)
    }

    @Test func stoppingTurnsFocusOffRightAway() async {
        controller.start()
        controller.hush(.indefinitely)
        await settle()
        controller.stop()
        #expect(switcher.offNowCount == 1)
        #expect(!controller.isEngaged)
        #expect(controller.manual == nil)
    }

    @Test func stoppingWhenNothingIsHushedRunsNothing() {
        controller.start()
        controller.stop()
        #expect(switcher.offNowCount == 0)
    }

    @Test func aCrashLeftoverIsTurnedOffAtStart() async {
        defaults.set(true, forKey: PreferenceKey.hushEngagedByCheese)
        controller.start()
        for _ in 0..<100 where switcher.offCount == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(switcher.offCount == 1)
        #expect(!defaults.bool(forKey: PreferenceKey.hushEngagedByCheese))
    }

    @Test func automaticToggleIsRemembered() {
        controller.setAutomatic(false)
        #expect(defaults.object(forKey: PreferenceKey.hushAutomatically) as? Bool == false)
        #expect(!controller.automatic)
    }

    @Test func testReportsMissingShortcuts() async {
        switcher.missing = ["Cheese Hush Off"]
        let result = await controller.test()
        #expect(result == "Missing: “Cheese Hush Off”")
        #expect(controller.setup == .missing(["Cheese Hush Off"]))
    }

    @Test func moduleActionsAndMenu() {
        let module = HushModule(controller: controller, statusItem: nil)
        let ids = module.actions.map(\.id)
        #expect(Set(ids) == Set(MenuLayout.actionIDs(in: MenuLayout.hush)))
        #expect(module.actions.first { $0.id == .hushIndefinitely }?.shortcut == .hush)
        #expect(module.actions.first { $0.id == .hush(.oneHour) }?.title == "Hush: For 1 Hour")
        #expect(module.actions.first { $0.id == .hushOff }?.precondition() == false)
        #expect(module.actions.first { $0.id == .hushAutomatically }?.isChecked?() == true)
    }
}

struct HushMenuTests {
    @Test func hushMenuReadsTopToBottom() {
        let visible = MenuLayout.visible(MenuLayout.hush) { $0 != .hushOff }
        let ids = visible.map { node -> String in
            if case let .action(id, _, _) = node { return id.rawValue }
            return "—"
        }
        #expect(ids == [
            "hushStatus", "—", "hushAutomatically", "—",
            "hush.thirtyMinutes", "hush.oneHour", "hush.twoHours", "hushUntil", "hushIndefinitely",
            "—", "hushSettings",
        ])
    }
}
