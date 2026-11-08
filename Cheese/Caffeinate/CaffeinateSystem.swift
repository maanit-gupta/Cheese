import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import os

// The system calls behind Caffeinate, each behind a small protocol so `CaffeinateController`
// is tested with fakes.

/// Whether the root helper is installed, and whether it's this version.
enum CaffeinateHelperStatus: Equatable, Sendable {
    case notInstalled
    case outdated
    case installed
}

enum CaffeinateHelperInstallResult: Equatable, Sendable {
    case done
    /// The user dismissed the password prompt.
    case cancelled
    case failed(String)
}

/// The root helper that keeps the Mac awake with the lid closed.
@MainActor
protocol CaffeinateHelping: AnyObject {
    var status: CaffeinateHelperStatus { get }
    func install() async -> CaffeinateHelperInstallResult
    func uninstall() async -> CaffeinateHelperInstallResult
    /// Asks the helper to keep lid-close sleep off until `deadline` (nil: until withdrawn).
    func request(deadline: Date?, batteryFloor: Int) throws
    /// Withdraws the request. `expired` ends it as if the time ran out, so a shut Mac sleeps.
    func withdraw(expired: Bool, batteryFloor: Int)
    func isSleepDisabled() async -> Bool
}

/// The real helper, in `/Library`.
@MainActor
final class SystemCaffeinateHelper: CaffeinateHelping {
    private let fileManager = FileManager.default
    private let pid = ProcessInfo.processInfo.processIdentifier

    var status: CaffeinateHelperStatus {
        guard fileManager.fileExists(atPath: CaffeinateHelperFiles.plistPath),
              let script = try? String(contentsOfFile: CaffeinateHelperFiles.helperPath, encoding: .utf8)
        else { return .notInstalled }
        return CaffeinateHelperFiles.isCurrent(installedScript: script) ? .installed : .outdated
    }

    func install() async -> CaffeinateHelperInstallResult {
        let result = await PrivilegedShell.runPrivileged(
            CaffeinateHelperFiles.installScript(uid: getuid()),
            prompt: "Cheese wants to install a small helper so it can keep your Mac awake with the lid closed. You'll only be asked once."
        )
        return Self.installResult(result, action: "install")
    }

    func uninstall() async -> CaffeinateHelperInstallResult {
        let result = await PrivilegedShell.runPrivileged(
            CaffeinateHelperFiles.uninstallScript,
            prompt: "Cheese wants to remove its lid-closed keep-awake helper."
        )
        return Self.installResult(result, action: "remove")
    }

    func request(deadline: Date?, batteryFloor: Int) throws {
        try write(CaffeinateHelperFiles.request(pid: pid, deadline: deadline, batteryFloor: batteryFloor))
    }

    func withdraw(expired: Bool, batteryFloor: Int) {
        if expired {
            try? write(CaffeinateHelperFiles.expiredRequest(pid: pid, batteryFloor: batteryFloor))
        } else {
            try? fileManager.removeItem(atPath: CaffeinateHelperFiles.requestPath)
        }
    }

    func isSleepDisabled() async -> Bool {
        await PrivilegedShell.isSleepDisabled()
    }

    /// Atomic, so the file is replaced by a rename: launchd sees the folder change and runs the helper.
    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: CaffeinateHelperFiles.requestPath), options: .atomic)
    }

    private static func installResult(_ result: PrivilegedShell.Result, action: String) -> CaffeinateHelperInstallResult {
        if result.status == 0 { return .done }
        if PrivilegedShell.isUserCancelled(osascriptError: result.output) { return .cancelled }
        Logger.caffeinate.error("Couldn't \(action, privacy: .public) the helper: \(result.output, privacy: .public)")
        return .failed(result.output)
    }
}

/// The power assertions that keep the Mac and display from idle sleep while the lid is open.
@MainActor
protocol SleepAssertions: AnyObject {
    /// Holds them, replacing any held before; `timeout` makes the system drop them on its own.
    func hold(timeout: TimeInterval?) -> Bool
    func release()
}

/// IOKit assertions, which the system drops by itself at their timeout and if Cheese exits.
/// While held, App Nap is off so the countdown and battery checks run on time.
@MainActor
final class SystemSleepAssertions: SleepAssertions {
    private let name: String
    private var ids: [IOPMAssertionID] = []
    private var activity: NSObjectProtocol?

    /// `name` is how `pmset -g assertions` lists them.
    init(name: String = "Cheese Caffeinate") {
        self.name = name
    }

    func hold(timeout: TimeInterval?) -> Bool {
        var created: [IOPMAssertionID] = []
        for type in [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep] {
            var id = IOPMAssertionID(0)
            let seconds = timeout.map { max($0, 1) } ?? 0
            let result = IOPMAssertionCreateWithDescription(
                type as CFString,
                name as CFString,
                nil,
                nil,
                nil,
                seconds,
                seconds > 0 ? kIOPMAssertionTimeoutActionRelease as CFString : nil,
                &id
            )
            guard result == kIOReturnSuccess else {
                Logger.caffeinate.error("Couldn't create a power assertion: \(result)")
                created.forEach { IOPMAssertionRelease($0) }
                return false
            }
            created.append(id)
        }
        // Take the new ones before letting the old ones go, so there's no gap.
        ids.forEach { IOPMAssertionRelease($0) }
        ids = created
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "\(name) countdown"
            )
        }
        return true
    }

    func release() {
        ids.forEach { IOPMAssertionRelease($0) }
        ids = []
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

/// The internal battery's charge, when the Mac is running on it.
struct BatteryState: Equatable, Sendable {
    var isOnBattery: Bool
    var percent: Int

    /// Reads IOKit power source descriptions; nil without an internal battery.
    static func from(descriptions: [[String: Any]]) -> BatteryState? {
        for description in descriptions where description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return BatteryState(isOnBattery: onBattery, percent: Int((Double(current) * 100 / Double(maximum)).rounded()))
        }
        return nil
    }

    /// Whether a session should stop at `floor` percent (0 = never).
    func isAtOrBelow(floor: Int) -> Bool {
        floor > 0 && isOnBattery && percent <= floor
    }
}

@MainActor
protocol BatteryReading {
    func current() -> BatteryState?
}

struct SystemBattery: BatteryReading {
    func current() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return BatteryState.from(descriptions: descriptions)
    }
}

/// Undoes a lid-closed session from Cheese 2.2.1's per-session watchdog, which could leave
/// lid-close sleep disabled. Asks once, then forgets; remove after one release.
@MainActor
enum LegacyLidAwake {
    private static let markerKey = "lidAwakeMayBeActive"

    static func recoverIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: markerKey) else { return }
        defaults.removeObject(forKey: markerKey)
        Task {
            // The new helper put it there itself and will put it back.
            guard await PrivilegedShell.isSleepDisabled(),
                  !FileManager.default.fileExists(atPath: CaffeinateHelperFiles.ownedMarkerPath)
            else { return }
            let result = await PrivilegedShell.runPrivileged(
                "\(PrivilegedShell.pmset) -a disablesleep 0",
                prompt: "An earlier version of Cheese left your Mac unable to sleep with the lid closed. Enter your password to let it sleep normally again."
            )
            if result.status == 0 {
                CheeseToast.show("Your Mac sleeps with the lid closed again", systemImage: "moon.zzz")
            }
        }
    }
}
