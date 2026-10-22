import Foundation
import IOKit.pwr_mgt
import os

/// Keeps the display and system from idle sleep with an IOKit power assertion,
/// either until turned off or until a chosen time.
@MainActor
final class KeepAwakeController {
    enum State: Equatable {
        case off
        case indefinite
        case until(Date)
    }

    /// The countdown text for the menu bar, or nil when keep awake is off.
    var onIndicatorChange: (String?) -> Void = { _ in }

    private(set) var state = State.off
    private var assertionID: IOPMAssertionID?
    private var tickTask: Task<Void, Never>?

    var isActive: Bool { state != .off }

    func keepAwakeIndefinitely() {
        start(.indefinite)
    }

    func keepAwake(until date: Date) {
        guard date > .now else { return }
        start(.until(date))
    }

    func turnOff() {
        tickTask?.cancel()
        tickTask = nil
        releaseAssertion()
        if state != .off {
            Logger.keepAwake.info("Keep awake off")
        }
        state = .off
        onIndicatorChange(nil)
    }

    private func start(_ newState: State) {
        tickTask?.cancel()
        guard createAssertionIfNeeded() else {
            turnOff()
            return
        }
        state = newState
        switch newState {
        case .off:
            break
        case .indefinite:
            Logger.keepAwake.info("Keep awake on, indefinitely")
            onIndicatorChange(KeepAwakeSchedule.indefiniteText)
        case let .until(date):
            Logger.keepAwake.info("Keep awake on until \(date, privacy: .public)")
            tickTask = Task { [weak self] in await self?.countDown(to: date) }
        }
    }

    /// Updates the indicator whenever its text would change, and turns off at the end.
    private func countDown(to date: Date) async {
        while !Task.isCancelled {
            let remaining = date.timeIntervalSinceNow
            guard remaining > 0 else {
                turnOff()
                return
            }
            onIndicatorChange(KeepAwakeSchedule.indicatorText(remaining: remaining))
            try? await Task.sleep(for: .seconds(KeepAwakeSchedule.nextRefresh(remaining: remaining)))
        }
    }

    private func createAssertionIfNeeded() -> Bool {
        guard assertionID == nil else { return true }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Cheese Keep Awake" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            Logger.keepAwake.error("Couldn't create the power assertion: \(result)")
            return false
        }
        assertionID = id
        return true
    }

    private func releaseAssertion() {
        guard let assertionID else { return }
        IOPMAssertionRelease(assertionID)
        self.assertionID = nil
    }
}
