import AppKit
import SwiftUI

/// What the Auto-Kill panel shows: the running apps, the scope, which are shielded, and whether
/// Option is down (which turns every quit into a force quit).
@MainActor
@Observable
final class AppSweepPanelModel {
    private(set) var apps: [RunningAppInfo] = []
    var scope = SweepScope.all
    var isOptionHeld = false
    private(set) var protectedIDs: Set<String> = []
    private(set) var activeAppName: String?

    @ObservationIgnored var onKillAll: (SweepPlan, _ force: Bool) -> Void = { _, _ in }
    @ObservationIgnored var onQuit: (RunningAppInfo, _ force: Bool) -> Void = { _, _ in }
    @ObservationIgnored var onClose: () -> Void = {}

    @ObservationIgnored private let source: any AppTerminating
    @ObservationIgnored private let protectedApps: ProtectedAppsStore
    @ObservationIgnored private let icon: (pid_t) -> NSImage?
    @ObservationIgnored private var icons: [pid_t: NSImage] = [:]
    @ObservationIgnored private var activePID: pid_t?
    @ObservationIgnored let ownBundleID = Bundle.main.bundleIdentifier
    @ObservationIgnored let ownPID = ProcessInfo.processInfo.processIdentifier

    init(source: any AppTerminating, protectedApps: ProtectedAppsStore, icon: @escaping (pid_t) -> NSImage?) {
        self.source = source
        self.protectedApps = protectedApps
        self.icon = icon
    }

    var plan: SweepPlan {
        AppSweepPlanner.plan(apps: apps, protectedBundleIDs: protectedIDs, scope: scope, ownBundleID: ownBundleID, ownPID: ownPID)
    }

    /// Fresh state for opening the panel over `activeApp`.
    func prepare(activeApp: NSRunningApplication?) {
        activePID = activeApp?.processIdentifier
        activeAppName = activeApp?.localizedName
        scope = .all
        icons = [:]
        refresh()
    }

    func refresh() {
        protectedIDs = protectedApps.bundleIDs
        apps = source.runningApps(activePID: activePID)
            .filter { AppSweepPlanner.isListed($0, ownBundleID: ownBundleID, ownPID: ownPID) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func icon(for app: RunningAppInfo) -> NSImage? {
        if let cached = icons[app.pid] { return cached }
        let image = icon(app.pid)
        icons[app.pid] = image
        return image
    }

    func isProtected(_ app: RunningAppInfo) -> Bool {
        app.bundleID.map(protectedIDs.contains) ?? false
    }

    func toggleShield(_ app: RunningAppInfo) {
        guard let bundleID = app.bundleID else { return }
        protectedApps.toggle(bundleID)
        protectedIDs = protectedApps.bundleIDs
    }

    /// Why an app stays open, if it does.
    func status(of app: RunningAppInfo) -> String? {
        if AppSweepPlanner.isAlwaysKept(app) { return "Always kept" }
        if isProtected(app) { return "Protected" }
        if scope == .keepFrontmost, app.isActive { return "Kept open" }
        return nil
    }

    func killAll(force: Bool) {
        onKillAll(plan, force)
    }

    func quit(_ app: RunningAppInfo) {
        onQuit(app, isOptionHeld)
    }
}

/// The Auto-Kill panel in its `CheesePanel`, kept current as apps launch and quit.
@MainActor
final class AppSweepPanelController {
    private let model: AppSweepPanelModel
    private var panel: CheesePanel?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var flagMonitors: [Any] = []

    init(model: AppSweepPanelModel) {
        self.model = model
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func show(activeApp: NSRunningApplication?) {
        model.prepare(activeApp: activeApp)
        model.isOptionHeld = NSEvent.modifierFlags.contains(.option)
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.present(at: .centered)
        observe()
    }

    func close() {
        stopObserving()
        guard panel?.isVisible == true else { return }
        panel?.dismiss()
    }

    private func makePanel() -> CheesePanel {
        let panel = CheesePanel(rootView: AppSweepPanelView(model: model))
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    private func observe() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refresh() }
            })
        }
        // Option turns Kill All into Force Kill All live, whether or not the panel is key.
        let update: (NSEvent) -> Void = { [weak self] event in
            let isOption = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated { self?.model.isOptionHeld = isOption }
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            update(event)
            return event
        }) {
            flagMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: update) {
            flagMonitors.append(global)
        }
    }

    private func stopObserving() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        for monitor in flagMonitors {
            NSEvent.removeMonitor(monitor)
        }
        flagMonitors.removeAll()
    }
}

private struct AppSweepPanelView: View {
    static let size = CGSize(width: 360, height: 420)

    @Bindable var model: AppSweepPanelModel

    var body: some View {
        let plan = model.plan
        VStack(spacing: 0) {
            header
            VStack(spacing: DesignTokens.Spacing.medium) {
                killAllButton(plan)
                Picker("Scope", selection: $model.scope) {
                    Text("All Apps").tag(SweepScope.all)
                    Text("Keep \(model.activeAppName ?? "Active App")").tag(SweepScope.keepFrontmost)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, DesignTokens.Spacing.panel)
            .padding(.bottom, DesignTokens.Spacing.medium)
            CheeseDivider()
            list(plan)
            CheeseDivider()
            Text(model.isOptionHeld ? "Force quitting skips “Save changes?” — unsaved work is lost." : "Shielded apps stay open. Hold ⌥ to force quit.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(model.isOptionHeld ? .red : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.panel)
                .padding(.vertical, DesignTokens.Spacing.small)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .cheesePanelBackground()
    }

    private var header: some View {
        CheeseToolbar {
            Image(systemName: ModuleID.appSweep.symbol)
                .foregroundStyle(.tint)
            Text("Auto-Kill")
                .font(DesignTokens.Typography.heading)
        } trailing: {
            CheeseIconButton(symbol: "xmark", help: "Close") { model.onClose() }
        }
    }

    private func killAllButton(_ plan: SweepPlan) -> some View {
        let force = model.isOptionHeld
        return ZStack {
            Button {
                model.killAll(force: force)
            } label: {
                Label(AppSweepPlanner.buttonTitle(count: plan.targets.count, force: force), systemImage: force ? "bolt.fill" : "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(force ? .red : .accentColor)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            // ⌥Return: the same button, forced.
            Button("") { model.killAll(force: true) }
                .keyboardShortcut(.return, modifiers: .option)
                .hidden()
                .accessibilityHidden(true)
        }
        .disabled(plan.targets.isEmpty)
    }

    private func list(_ plan: SweepPlan) -> some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.hairline) {
                ForEach(model.apps) { app in
                    row(app, isTarget: plan.targets.contains(app))
                }
            }
            .padding(DesignTokens.Spacing.small)
        }
        .overlay {
            if model.apps.isEmpty {
                CheeseEmptyState(symbol: "checkmark.circle", title: "No open apps", detail: "There's nothing to sweep.")
            }
        }
    }

    private func row(_ app: RunningAppInfo, isTarget: Bool) -> some View {
        let isProtected = model.isProtected(app)
        let isAlwaysKept = AppSweepPlanner.isAlwaysKept(app)
        return CheeseListRow(
            symbol: "app",
            title: app.name,
            detail: model.status(of: app),
            isDimmed: !isTarget,
            icon: model.icon(for: app)
        ) {
            if !isAlwaysKept {
                if app.bundleID != nil {
                    CheeseIconButton(
                        symbol: isProtected ? "lock.fill" : "lock.open",
                        help: isProtected ? "Protected from Kill All. Click to unprotect" : "Protect from Kill All",
                        isActive: isProtected
                    ) {
                        model.toggleShield(app)
                    }
                }
                CheeseIconButton(symbol: "xmark", help: model.isOptionHeld ? "Force quit \(app.name)" : "Quit \(app.name)") {
                    model.quit(app)
                }
            }
        }
    }
}
