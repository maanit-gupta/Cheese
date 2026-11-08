import AppKit
import os

/// Shows the Sweep countdown and lock. A protocol so tests can watch it.
@MainActor
protocol SweepHUDPresenting: AnyObject {
    func show(_ content: SweepHUDContent)
    func close()
}

/// Sweep: a short countdown, then the keyboard and trackpad stay locked for the chosen time while
/// the screen and keyboard are wiped. Holding Esc for three seconds ends it early. The display
/// stays on throughout.
@MainActor
@Observable
final class SweepController {
    typealias ShowToast = @MainActor (_ message: String, _ systemImage: String) -> Void

    enum EndReason: Equatable {
        case finished
        case escHold
        /// The module was switched off or Cheese is quitting.
        case stopped
        /// macOS wouldn't let Cheese block input.
        case failed
    }

    private(set) var session: SweepSession?
    private(set) var isLocked = false
    private(set) var lastEnd: EndReason?

    var isActive: Bool { session != nil }

    @ObservationIgnored private let blocker: any InputBlocking
    @ObservationIgnored private let assertions: any SleepAssertions
    @ObservationIgnored private let hud: any SweepHUDPresenting
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let chime: @MainActor () -> Void
    @ObservationIgnored private let showToast: ShowToast
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var escHold = SweepEscHold()
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(
        blocker: any InputBlocking = EventTapInputBlocker(),
        assertions: any SleepAssertions = SystemSleepAssertions(name: "Cheese Sweep"),
        hud: any SweepHUDPresenting = SweepHUD(),
        now: @escaping @MainActor () -> Date = { .now },
        chime: @escaping @MainActor () -> Void = { NSSound(named: "Glass")?.play() },
        showToast: @escaping ShowToast = { CheeseToast.show($0, systemImage: $1) },
        tickInterval: Duration = .milliseconds(200)
    ) {
        self.blocker = blocker
        self.assertions = assertions
        self.hud = hud
        self.now = now
        self.chime = chime
        self.showToast = showToast
        self.tickInterval = tickInterval
        blocker.onEscape = { [weak self] isDown in self?.escapeChanged(isDown) }
    }

    /// Starts the countdown. Does nothing while a Sweep is already on.
    func start(duration: TimeInterval) {
        guard session == nil else { return }
        let session = SweepSession(startedAt: now(), duration: duration)
        self.session = session
        lastEnd = nil
        escHold = SweepEscHold()
        // The display stays on; the system drops the assertion by itself a little after the end.
        _ = assertions.hold(timeout: duration + TimeInterval(SweepSession.countdownSeconds) + 5)
        Logger.sweep.notice("Sweep started for \(Int(duration)) s")
        tick()
        guard self.session != nil else { return }
        tickTask = Task { [weak self, tickInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard let self, self.session != nil else { return }
                self.tick()
            }
        }
    }

    /// Moves the session along: shows the countdown, locks when it's done, ends on time or once
    /// Esc has been held long enough. Runs a few times a second while a Sweep is on.
    func tick() {
        guard let session else { return }
        let now = now()
        if isLocked, escHold.isComplete(at: now) {
            end(.escHold)
            return
        }
        switch session.state(at: now) {
        case let .countingDown(secondsLeft):
            hud.show(.countdown(secondsLeft))
        case let .locked(secondsLeft):
            if !isLocked {
                guard blocker.block() else {
                    end(.failed)
                    return
                }
                isLocked = true
            }
            hud.show(.locked(secondsLeft, holdingEsc: escHold.isHolding))
        case .finished:
            end(.finished)
        }
    }

    /// Ends any Sweep at once, quietly: the module is going off or Cheese is quitting.
    func stop() {
        guard session != nil else { return }
        end(.stopped)
    }

    private func escapeChanged(_ isDown: Bool) {
        guard isLocked else { return }
        if isDown {
            escHold.keyDown(at: now())
        } else {
            escHold.keyUp()
        }
        tick()
    }

    private func end(_ reason: EndReason) {
        tickTask?.cancel()
        tickTask = nil
        if isLocked {
            blocker.unblock()
            isLocked = false
        }
        assertions.release()
        hud.close()
        session = nil
        escHold = SweepEscHold()
        lastEnd = reason
        Logger.sweep.notice("Sweep ended: \(String(describing: reason))")
        switch reason {
        case .finished, .escHold:
            chime()
            showToast("Keyboard and trackpad unlocked", "checkmark.circle.fill")
        case .failed:
            showToast("Couldn't lock the keyboard and trackpad", "exclamationmark.triangle.fill")
        case .stopped:
            break
        }
    }
}
