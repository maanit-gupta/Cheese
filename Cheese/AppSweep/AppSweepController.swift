import AppKit

/// Auto-Kill: the panel, and sweeps straight from a hotkey or the palette. Every sweep honors the
/// shields and never touches Cheese, Finder or background helpers (see `AppSweepPlanner`).
@MainActor
final class AppSweepController {
    private let apps: any AppTerminating
    private let sweeper: AppSweeper
    private let protectedApps: ProtectedAppsStore
    private let preferences: Preferences
    private lazy var panel: AppSweepPanelController = makePanel()

    init(apps: any AppTerminating = SystemApps(), protectedApps: ProtectedAppsStore = ProtectedAppsStore(), preferences: Preferences = Preferences()) {
        self.apps = apps
        sweeper = AppSweeper(apps: apps)
        self.protectedApps = protectedApps
        self.preferences = preferences
    }

    /// Opens the panel. `activeApp` is the app the user was in, which "Keep Active App" leaves open.
    func showPanel(activeApp: NSRunningApplication?) {
        panel.show(activeApp: activeApp)
    }

    func closePanel() {
        panel.close()
    }

    /// Sweeps without the panel: ⌃⌥⇧Q and the palette's Kill actions.
    func sweepNow(scope: SweepScope, force: Bool, activeApp: NSRunningApplication?) {
        let plan = AppSweepPlanner.plan(
            apps: apps.runningApps(activePID: activeApp?.processIdentifier),
            protectedBundleIDs: protectedApps.bundleIDs,
            scope: scope,
            ownBundleID: Bundle.main.bundleIdentifier,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        run(plan, force: force)
    }

    private func run(_ plan: SweepPlan, force: Bool) {
        guard !plan.targets.isEmpty else {
            CheeseToast.show(plan.protected.isEmpty ? "No open apps to sweep" : "Every open app is protected", systemImage: "info.circle")
            return
        }
        CheeseToast.show(AppSweepPlanner.summary(swept: plan.targets.count, protected: plan.protected.count), systemImage: ModuleID.appSweep.symbol)
        let gracePeriod = force || preferences.autoKillForcesStragglers ? AppSweeper.forceGracePeriod : nil
        Task { [sweeper] in
            await sweeper.sweep(plan.targets, forceAfter: gracePeriod)
        }
    }

    private func makePanel() -> AppSweepPanelController {
        let model = AppSweepPanelModel(source: apps, protectedApps: protectedApps) { pid in
            NSRunningApplication(processIdentifier: pid)?.icon
        }
        let panel = AppSweepPanelController(model: model)
        model.onClose = { [weak panel] in panel?.close() }
        model.onKillAll = { [weak self, weak panel] plan, force in
            panel?.close()
            self?.run(plan, force: force)
        }
        model.onQuit = { [sweeper] app, force in sweeper.quit(app, force: force) }
        return panel
    }
}
