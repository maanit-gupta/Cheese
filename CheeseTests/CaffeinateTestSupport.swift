import Foundation
@testable import Cheese

/// A helper that records what Caffeinate asks of it, and disables "sleep" when told to.
@MainActor
final class FakeCaffeinateHelper: CaffeinateHelping {
    var status: CaffeinateHelperStatus = .installed
    var installResult: CaffeinateHelperInstallResult = .done
    /// False to act like a helper macOS won't let run.
    var takesEffect = true
    /// Holds `install()` until `finishInstall()` is called, like a password prompt left open.
    var holdsInstall = false
    private var pendingInstall: CheckedContinuation<Void, Never>?

    private(set) var installs = 0
    private(set) var uninstalls = 0
    private(set) var requests: [(deadline: Date?, floor: Int)] = []
    private(set) var withdrawals: [Bool] = []
    private(set) var sleepDisabled = false

    func install() async -> CaffeinateHelperInstallResult {
        installs += 1
        if holdsInstall {
            await withCheckedContinuation { pendingInstall = $0 }
        }
        if installResult == .done { status = .installed }
        return installResult
    }

    func finishInstall() {
        pendingInstall?.resume()
        pendingInstall = nil
    }

    func uninstall() async -> CaffeinateHelperInstallResult {
        uninstalls += 1
        status = .notInstalled
        sleepDisabled = false
        return .done
    }

    func request(deadline: Date?, batteryFloor: Int) throws {
        requests.append((deadline, batteryFloor))
        if takesEffect { sleepDisabled = true }
    }

    func withdraw(expired: Bool, batteryFloor: Int) {
        withdrawals.append(expired)
        sleepDisabled = false
    }

    func isSleepDisabled() async -> Bool {
        sleepDisabled
    }
}

@MainActor
final class FakeSleepAssertions: SleepAssertions {
    var succeeds = true
    private(set) var holds: [TimeInterval?] = []
    private(set) var isHeld = false

    func hold(timeout: TimeInterval?) -> Bool {
        guard succeeds else { return false }
        holds.append(timeout)
        isHeld = true
        return true
    }

    func release() {
        isHeld = false
    }
}

@MainActor
final class FakeBattery: BatteryReading {
    var state: BatteryState?

    func current() -> BatteryState? {
        state
    }
}

/// A clock tests move by hand.
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// A controller over fakes, with its toasts and indicator recorded.
@MainActor
final class CaffeinateHarness {
    let helper = FakeCaffeinateHelper()
    let assertions = FakeSleepAssertions()
    let battery = FakeBattery()
    let clock = FakeClock()
    let defaults: UserDefaults
    private(set) var toasts: [String] = []
    private(set) var indicator: String?
    private(set) var controller: CaffeinateController!

    init(lidClosed: Bool = true, batteryFloor: Int? = nil) {
        let suite = "CaffeinateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set(lidClosed, forKey: PreferenceKey.caffeinateLidClosed)
        if let batteryFloor {
            defaults.set(batteryFloor, forKey: PreferenceKey.caffeinateBatteryFloor)
        }
        let clock = clock
        controller = CaffeinateController(
            helper: helper,
            assertions: assertions,
            battery: battery,
            defaults: defaults,
            verifyTimeout: .milliseconds(50),
            pollInterval: .milliseconds(5),
            now: { clock.now },
            showToast: { [weak self] message, _, _ in self?.toasts.append(message) }
        )
        controller.onIndicatorChange = { [weak self] in self?.indicator = $0 }
    }

    /// Lets the lid-cover task finish.
    func settle() async {
        for _ in 0..<200 where controller.isCoveringLid {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
