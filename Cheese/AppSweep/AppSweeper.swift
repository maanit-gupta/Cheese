import AppKit
import os

/// The running apps, and quitting them. Behind a protocol so the sweep's timing is tested with fakes.
@MainActor
protocol AppTerminating {
    /// Every running app. `activePID` is the app the user is working in.
    func runningApps(activePID: pid_t?) -> [RunningAppInfo]
    /// Asks the app to quit, as ⌘Q does: it can save, ask about unsaved changes, or refuse.
    func terminate(_ pid: pid_t)
    /// Quits the app at once, without saving.
    func forceTerminate(_ pid: pid_t)
    func isRunning(_ pid: pid_t) -> Bool
}

/// `AppTerminating` over `NSWorkspace` and `NSRunningApplication`.
struct SystemApps: AppTerminating {
    func runningApps(activePID: pid_t?) -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.map { app in
            RunningAppInfo(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "App",
                isRegular: app.activationPolicy == .regular,
                isActive: app.processIdentifier == activePID
            )
        }
    }

    func terminate(_ pid: pid_t) {
        if NSRunningApplication(processIdentifier: pid)?.terminate() == false {
            Logger.appSweep.info("App \(pid) didn't accept the quit request")
        }
    }

    func forceTerminate(_ pid: pid_t) {
        if NSRunningApplication(processIdentifier: pid)?.forceTerminate() == false {
            Logger.appSweep.error("Couldn't force-quit app \(pid)")
        }
    }

    func isRunning(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
    }
}

/// Quits a sweep's apps all at once, then, when asked, force-quits whatever is still open after a
/// grace period.
@MainActor
final class AppSweeper {
    /// How long apps get to quit on their own before a force sweep kills them.
    static let forceGracePeriod = Duration.seconds(3)

    struct Result: Equatable {
        /// Apps asked to quit.
        var asked: Int
        /// Of those, the ones still open after the grace period and force-quit.
        var forced: Int
    }

    private let apps: any AppTerminating
    private let pollInterval: Duration

    init(apps: any AppTerminating, pollInterval: Duration = .milliseconds(100)) {
        self.apps = apps
        self.pollInterval = pollInterval
    }

    /// - Parameter forceAfter: nil only asks; otherwise apps still running after this long are force-quit.
    @discardableResult
    func sweep(_ targets: [RunningAppInfo], forceAfter gracePeriod: Duration?) async -> Result {
        // Every request goes out before any waiting, so the apps quit side by side.
        for app in targets {
            apps.terminate(app.pid)
        }
        guard let gracePeriod else { return Result(asked: targets.count, forced: 0) }

        let deadline = ContinuousClock.now + gracePeriod
        var remaining = targets.filter { apps.isRunning($0.pid) }
        while !remaining.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            remaining = remaining.filter { apps.isRunning($0.pid) }
        }
        for app in remaining {
            apps.forceTerminate(app.pid)
        }
        if !remaining.isEmpty {
            Logger.appSweep.info("Force-quit \(remaining.count) apps that were still open")
        }
        return Result(asked: targets.count, forced: remaining.count)
    }

    /// Quits one app from the panel's ×, or kills it outright with Option held.
    func quit(_ app: RunningAppInfo, force: Bool) {
        if force {
            apps.forceTerminate(app.pid)
        } else {
            apps.terminate(app.pid)
        }
    }
}
