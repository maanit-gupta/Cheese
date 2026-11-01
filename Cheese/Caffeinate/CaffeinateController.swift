import AppKit
import Observation
import os

/// One Caffeinate session at a time: idle-sleep assertions for its length and, when "Keep Awake
/// With Lid Closed" is on, the root helper keeping lid-close sleep off too. Ends on Turn Off, when
/// its time runs out, when the battery reaches the floor, or when Cheese stops; the helper puts
/// lid-close sleep back (and sleeps a shut Mac whose time ran out) even if Cheese crashes.
@MainActor
@Observable
final class CaffeinateController {
    struct Session: Equatable {
        var duration: CaffeinateDuration
        var deadline: Date?
        /// Whether the helper has lid-close sleep off for this session right now.
        var coversLid = false
    }

    enum EndReason: Equatable {
        case user
        case expired
        case battery(percent: Int)
        /// Module off or quit: no toast.
        case stopping
    }

    typealias ShowToast = @MainActor (_ message: String, _ symbol: String, _ action: CheeseToast.Action?) -> Void

    private(set) var session: Session?
    /// Whether sessions keep the Mac awake with the lid closed too.
    private(set) var wantsLid: Bool
    /// Waiting on the password prompt or for the helper to take effect.
    private(set) var isCoveringLid = false
    private(set) var helperStatus: CaffeinateHelperStatus = .notInstalled
    /// Installed, but macOS isn't letting it run (Login Items → Allow in the Background is off).
    private(set) var isHelperBlocked = false

    var isActive: Bool { session != nil }

    /// The countdown for the menu bar, or nil when off.
    @ObservationIgnored var onIndicatorChange: (String?) -> Void = { _ in }

    @ObservationIgnored private let helper: any CaffeinateHelping
    @ObservationIgnored private let assertions: any SleepAssertions
    @ObservationIgnored private let battery: any BatteryReading
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let showToast: ShowToast
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let verifyTimeout: Duration
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var lidTask: Task<Void, Never>?
    /// Bumped whenever lid coverage is withdrawn, so a password prompt answered late can't
    /// bring it back.
    @ObservationIgnored private var lidGeneration = 0
    @ObservationIgnored private var hasRequest = false

    static let loginItemsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    init(
        helper: any CaffeinateHelping = SystemCaffeinateHelper(),
        assertions: any SleepAssertions = SystemSleepAssertions(),
        battery: any BatteryReading = SystemBattery(),
        defaults: UserDefaults = .standard,
        verifyTimeout: Duration = .seconds(4),
        pollInterval: Duration = .milliseconds(250),
        now: @escaping @MainActor () -> Date = { .now },
        showToast: @escaping ShowToast = { CheeseToast.show($0, systemImage: $1, action: $2) }
    ) {
        self.helper = helper
        self.assertions = assertions
        self.battery = battery
        self.defaults = defaults
        self.verifyTimeout = verifyTimeout
        self.pollInterval = pollInterval
        self.now = now
        self.showToast = showToast
        wantsLid = Preferences(defaults: defaults).caffeinateLidClosed
    }

    private var batteryFloor: Int { Preferences(defaults: defaults).caffeinateBatteryFloor }

    // MARK: - Sessions

    /// Starts a session, or changes the length of the one running (no new password prompt).
    func start(_ duration: CaffeinateDuration) {
        let start = now()
        let deadline = duration.deadline(from: start)
        if let deadline, deadline <= start { return }
        if let state = battery.current(), state.isAtOrBelow(floor: batteryFloor) {
            showToast(
                "Battery is at \(state.percent)%, so Caffeinate stays off. Change the limit in Settings → Caffeinate.",
                "battery.25",
                nil
            )
            return
        }
        guard assertions.hold(timeout: deadline.map { $0.timeIntervalSince(start) }) else {
            end(.stopping)
            showToast("Couldn't keep your Mac awake", "exclamationmark.triangle.fill", nil)
            return
        }
        let coversLid = wantsLid && (session?.coversLid ?? false)
        session = Session(duration: duration, deadline: deadline, coversLid: coversLid)
        Logger.caffeinate.notice("Caffeinate on \(duration.phrase(), privacy: .public)")
        startTicking()
        updateIndicator()
        if wantsLid {
            coverLid(announcing: true)
        } else {
            announce()
        }
    }

    func turnOff() {
        end(.user)
    }

    /// Module off or quit. Also withdraws a request a previous run may have left.
    func stop() {
        if session != nil {
            end(.stopping)
        } else {
            withdraw(expired: false)
        }
    }

    /// Turns lid-closed cover on or off, for this session and the next ones.
    func setCoversLid(_ on: Bool) {
        wantsLid = on
        defaults.set(on, forKey: PreferenceKey.caffeinateLidClosed)
        guard var current = session else { return }
        if on {
            coverLid(announcing: true)
        } else {
            lidGeneration += 1
            isCoveringLid = false
            withdraw(expired: false)
            current.coversLid = false
            session = current
            updateIndicator()
            showToast("Closing the lid will sleep the Mac again", "laptopcomputer", nil)
        }
    }

    /// Passes a new battery floor to the helper for the running session.
    func batteryFloorChanged() {
        guard let session, session.coversLid else { return }
        try? helper.request(deadline: session.deadline, batteryFloor: batteryFloor)
    }

    // MARK: - Helper

    func refreshHelperStatus() {
        helperStatus = helper.status
    }

    func installHelper() async {
        let result = await helper.install()
        refreshHelperStatus()
        if case .failed = result {
            showToast("Couldn't install the Caffeinate helper", "exclamationmark.triangle.fill", nil)
        }
    }

    /// Removes the helper and stops covering the lid, so no session asks to install it again.
    func removeHelper() async {
        let result = await helper.uninstall()
        refreshHelperStatus()
        switch result {
        case .done:
            hasRequest = false
            isHelperBlocked = false
            if wantsLid { setCoversLid(false) }
        case .cancelled:
            break
        case .failed:
            showToast("Couldn't remove the Caffeinate helper", "exclamationmark.triangle.fill", nil)
        }
    }

    // MARK: - Lid

    private func coverLid(announcing: Bool) {
        // One at a time: a prompt already up picks up the session as it is when answered.
        guard !isCoveringLid else { return }
        isCoveringLid = true
        let generation = lidGeneration
        lidTask = Task { [weak self] in
            await self?.coverLid(generation: generation, announcing: announcing)
        }
    }

    private func coverLid(generation: Int, announcing: Bool) async {
        defer {
            if generation == lidGeneration { isCoveringLid = false }
        }
        refreshHelperStatus()
        if helperStatus != .installed {
            let result = await helper.install()
            refreshHelperStatus()
            guard generation == lidGeneration, session != nil else { return }
            switch result {
            case .done:
                Logger.caffeinate.notice("Caffeinate helper installed")
            case .cancelled:
                Logger.caffeinate.notice("Caffeinate helper install cancelled")
                if announcing {
                    announce(note: "Closing the lid will still sleep the Mac.")
                }
                return
            case .failed:
                showToast("Couldn't set up keeping your Mac awake with the lid closed", "exclamationmark.triangle.fill", nil)
                return
            }
        }
        guard let deadline = session.map(\.deadline) else { return }
        do {
            try helper.request(deadline: deadline, batteryFloor: batteryFloor)
            hasRequest = true
        } catch {
            Logger.caffeinate.error("Couldn't write the Caffeinate request: \(error.localizedDescription, privacy: .public)")
            showToast("Couldn't keep your Mac awake with the lid closed", "exclamationmark.triangle.fill", nil)
            return
        }
        let took = await waitUntilSleepDisabled()
        guard generation == lidGeneration, var current = session else { return }
        guard took else {
            Logger.caffeinate.error("The Caffeinate helper didn't disable lid-close sleep; it's likely not allowed to run")
            withdraw(expired: false)
            isHelperBlocked = true
            showToast(
                "macOS isn't letting Cheese's helper run, so closing the lid will sleep the Mac",
                "exclamationmark.triangle.fill",
                CheeseToast.Action(title: "Open") {
                    if let url = Self.loginItemsURL { NSWorkspace.shared.open(url) }
                }
            )
            return
        }
        isHelperBlocked = false
        let wasCovering = current.coversLid
        current.coversLid = true
        session = current
        updateIndicator()
        Logger.caffeinate.notice("Caffeinate covering a closed lid")
        if announcing || !wasCovering {
            announce()
        }
    }

    private func waitUntilSleepDisabled() async -> Bool {
        let clock = ContinuousClock()
        let giveUp = clock.now.advanced(by: verifyTimeout)
        while true {
            if await helper.isSleepDisabled() { return true }
            guard clock.now < giveUp, !Task.isCancelled else { return false }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func withdraw(expired: Bool) {
        helper.withdraw(expired: expired, batteryFloor: batteryFloor)
        hasRequest = false
    }

    // MARK: - Ending

    private func end(_ reason: EndReason) {
        lidGeneration += 1
        isCoveringLid = false
        lidTask?.cancel()
        lidTask = nil
        tickTask?.cancel()
        tickTask = nil
        assertions.release()
        let wasCovering = session?.coversLid ?? false
        if wasCovering || hasRequest {
            // Ending by time or battery tells the helper to sleep a Mac whose lid is shut.
            switch reason {
            case .expired, .battery: withdraw(expired: true)
            case .user, .stopping: withdraw(expired: false)
            }
        }
        let wasOn = session != nil
        session = nil
        updateIndicator()
        guard wasOn else { return }
        Logger.caffeinate.notice("Caffeinate off (\(String(describing: reason), privacy: .public))")
        switch reason {
        case .user: showToast("Caffeinate is off", "moon.zzz", nil)
        case .expired: showToast("Caffeinate ended", "moon.zzz", nil)
        case let .battery(percent): showToast("Caffeinate ended: battery at \(percent)%", "battery.25", nil)
        case .stopping: break
        }
    }

    // MARK: - Countdown

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled, let wait = self?.checkSession() {
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Ends the session if its time is up or the battery is at the floor, otherwise refreshes the
    /// countdown. Returns the seconds until the next check, or nil once the session is over.
    @discardableResult
    func checkSession() -> TimeInterval? {
        guard let session else { return nil }
        var remaining: TimeInterval?
        if let deadline = session.deadline {
            let left = deadline.timeIntervalSince(now())
            guard left > 0 else {
                end(.expired)
                return nil
            }
            remaining = left
        }
        if let state = battery.current(), state.isAtOrBelow(floor: batteryFloor) {
            end(.battery(percent: state.percent))
            return nil
        }
        updateIndicator()
        // At least once a minute, for the battery; every second in the final minute.
        return min(remaining.map { CaffeinateSchedule.nextRefresh(remaining: $0) } ?? 60, 60)
    }

    private func updateIndicator() {
        guard let session else {
            onIndicatorChange(nil)
            return
        }
        let text = session.deadline.map {
            CaffeinateSchedule.indicatorText(remaining: max($0.timeIntervalSince(now()), 0))
        } ?? CaffeinateSchedule.indefiniteText
        onIndicatorChange(session.coversLid ? "Lid \(text)" : text)
    }

    private func announce(note: String? = nil) {
        guard let session else { return }
        let lid = session.coversLid ? ", even with the lid closed" : ""
        let message = "Caffeinating \(session.duration.phrase())\(lid)" + (note.map { ". \($0)" } ?? "")
        showToast(message, session.coversLid ? "laptopcomputer" : "cup.and.saucer.fill", nil)
    }
}
