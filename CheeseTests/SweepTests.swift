import Foundation
import Testing
@testable import Cheese

@MainActor
final class FakeInputBlocker: InputBlocking {
    var onEscape: ((Bool) -> Void)?
    var succeeds = true
    private(set) var isBlocking = false
    private(set) var blockCount = 0

    func block() -> Bool {
        guard succeeds else { return false }
        blockCount += 1
        isBlocking = true
        return true
    }

    func unblock() {
        isBlocking = false
    }

    func escape(_ isDown: Bool) {
        onEscape?(isDown)
    }
}

@MainActor
final class FakeSweepHUD: SweepHUDPresenting {
    private(set) var shown: [SweepHUDContent] = []
    private(set) var isShowing = false

    func show(_ content: SweepHUDContent) {
        shown.append(content)
        isShowing = true
    }

    func close() {
        isShowing = false
    }
}

struct SweepDurationTests {
    @Test func offersTheSettingsPresetsWithThirtySecondsByDefault() {
        #expect(SweepDuration.allCases.map(\.rawValue) == [15, 30, 60, 90, 120])
        #expect(SweepDuration.standard == .thirtySeconds)
        #expect(SweepDuration.stored(nil) == .thirtySeconds)
        #expect(SweepDuration.stored(45) == .thirtySeconds)
        #expect(SweepDuration.stored(90) == .ninetySeconds)
        #expect(SweepDuration.twoMinutes.seconds == 120)
    }

    @Test func preferenceReadsTheStoredValue() throws {
        let defaults = try #require(UserDefaults(suiteName: "SweepDurationTests"))
        defaults.removePersistentDomain(forName: "SweepDurationTests")
        #expect(Preferences(defaults: defaults).sweepDuration == .thirtySeconds)
        defaults.set(60, forKey: PreferenceKey.sweepDuration)
        #expect(Preferences(defaults: defaults).sweepDuration == .oneMinute)
    }
}

struct SweepSessionTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func countsDownThenLocksThenFinishes() {
        let session = SweepSession(startedAt: start, duration: 30)
        #expect(session.state(at: start) == .countingDown(secondsLeft: 3))
        #expect(session.state(at: start + 0.5) == .countingDown(secondsLeft: 3))
        #expect(session.state(at: start + 1) == .countingDown(secondsLeft: 2))
        #expect(session.state(at: start + 2.9) == .countingDown(secondsLeft: 1))
        #expect(session.state(at: start + 3) == .locked(secondsLeft: 30))
        #expect(session.state(at: start + 32.5) == .locked(secondsLeft: 1))
        #expect(session.state(at: start + 33) == .finished)
        #expect(session.endsAt == start + 33)
    }

    @Test func hudTextShowsTheClock() {
        #expect(SweepHUDContent.clock(24) == "0:24")
        #expect(SweepHUDContent.clock(120) == "2:00")
        #expect(SweepHUDContent.clock(65) == "1:05")
        #expect(SweepHUDContent.locked(24, holdingEsc: false).title == "Sweep · 0:24")
        #expect(SweepHUDContent.locked(24, holdingEsc: false).detail.contains("Hold Esc for 3 seconds"))
        #expect(SweepHUDContent.locked(24, holdingEsc: true).detail == "Keep holding Esc to stop…")
        #expect(SweepHUDContent.countdown(2).title == "Locking keyboard and trackpad in 2…")
    }
}

struct SweepEscHoldTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func completesAfterThreeSecondsHeld() {
        var hold = SweepEscHold()
        #expect(!hold.isComplete(at: start))
        hold.keyDown(at: start)
        #expect(hold.isHolding)
        #expect(!hold.isComplete(at: start + 2.9))
        #expect(hold.isComplete(at: start + 3))
    }

    @Test func keyRepeatDoesntRestartTheCount() {
        var hold = SweepEscHold()
        hold.keyDown(at: start)
        hold.keyDown(at: start + 1)
        hold.keyDown(at: start + 2)
        #expect(hold.isComplete(at: start + 3))
    }

    @Test func lettingGoResetsIt() {
        var hold = SweepEscHold()
        hold.keyDown(at: start)
        hold.keyUp()
        #expect(!hold.isHolding)
        #expect(!hold.isComplete(at: start + 10))
        hold.keyDown(at: start + 10)
        #expect(!hold.isComplete(at: start + 12))
        #expect(hold.isComplete(at: start + 13))
    }
}

@MainActor
struct SweepControllerTests {
    let clock = FakeClock()
    let blocker = FakeInputBlocker()
    let assertions = FakeSleepAssertions()
    let hud = FakeSweepHUD()
    let toasts = ToastRecorder()
    let chimes = Counter()
    let controller: SweepController

    final class ToastRecorder {
        var messages: [String] = []
    }

    final class Counter {
        var count = 0
    }

    init() {
        let clock = clock
        let toasts = toasts
        let chimes = chimes
        controller = SweepController(
            blocker: blocker, assertions: assertions, hud: hud,
            now: { clock.now },
            chime: { chimes.count += 1 },
            showToast: { message, _ in toasts.messages.append(message) },
            tickInterval: .seconds(3600)
        )
    }

    @Test func countdownThenLockThenUnlockWithAChime() {
        controller.start(duration: 30)
        #expect(controller.isActive)
        #expect(!blocker.isBlocking)
        #expect(hud.shown.last == .countdown(3))
        #expect(assertions.isHeld)
        #expect(assertions.holds.first == 38)

        clock.advance(3)
        controller.tick()
        #expect(blocker.isBlocking)
        #expect(controller.isLocked)
        #expect(hud.shown.last == .locked(30, holdingEsc: false))

        clock.advance(30)
        controller.tick()
        #expect(!controller.isActive)
        #expect(!blocker.isBlocking)
        #expect(!assertions.isHeld)
        #expect(!hud.isShowing)
        #expect(chimes.count == 1)
        #expect(toasts.messages == ["Keyboard and trackpad unlocked"])
        #expect(controller.lastEnd == .finished)
    }

    @Test func holdingEscForThreeSecondsEndsItEarly() {
        controller.start(duration: 60)
        clock.advance(3)
        controller.tick()

        blocker.escape(true)
        #expect(hud.shown.last == .locked(60, holdingEsc: true))
        clock.advance(2)
        controller.tick()
        #expect(controller.isActive)
        clock.advance(1)
        controller.tick()
        #expect(!controller.isActive)
        #expect(!blocker.isBlocking)
        #expect(controller.lastEnd == .escHold)
        #expect(chimes.count == 1)
    }

    @Test func aBriefEscDoesNothing() {
        controller.start(duration: 60)
        clock.advance(3)
        controller.tick()
        blocker.escape(true)
        clock.advance(1)
        blocker.escape(false)
        clock.advance(5)
        controller.tick()
        #expect(controller.isActive)
        #expect(blocker.isBlocking)
    }

    @Test func escDuringTheCountdownIsIgnored() {
        controller.start(duration: 30)
        blocker.escape(true)
        clock.advance(3)
        controller.tick()
        clock.advance(3)
        controller.tick()
        #expect(controller.isActive)
    }

    @Test func stopEndsQuietly() {
        controller.start(duration: 30)
        clock.advance(4)
        controller.tick()
        controller.stop()
        #expect(!controller.isActive)
        #expect(!blocker.isBlocking)
        #expect(chimes.count == 0)
        #expect(toasts.messages.isEmpty)
        #expect(controller.lastEnd == .stopped)
    }

    @Test func stopDuringTheCountdownNeverLocks() {
        controller.start(duration: 30)
        controller.stop()
        clock.advance(10)
        controller.tick()
        #expect(blocker.blockCount == 0)
    }

    @Test func startingAgainWhileOnDoesNothing() {
        controller.start(duration: 30)
        clock.advance(1)
        controller.start(duration: 120)
        #expect(controller.session?.duration == 30)
    }

    @Test func refusedTapEndsWithAToast() {
        blocker.succeeds = false
        controller.start(duration: 30)
        clock.advance(3)
        controller.tick()
        #expect(!controller.isActive)
        #expect(controller.lastEnd == .failed)
        #expect(toasts.messages == ["Couldn't lock the keyboard and trackpad"])
        #expect(chimes.count == 0)
    }

    @Test func moduleOffersSweepOnlyWhileIdleAndNeedsAccessibility() {
        let module = SweepModule(controller: controller)
        let action = module.actions.first
        #expect(action?.id == .sweep)
        #expect(action?.requiredPermissions == [.accessibility])
        #expect(action?.shortcut == nil)
        #expect(action?.paletteTitle == "Control: Sweep (Clean Screen)")
        #expect(action?.precondition() == true)
        controller.start(duration: 30)
        #expect(action?.precondition() == false)
        module.stop()
        #expect(!controller.isActive)
    }
}
