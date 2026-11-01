import AppKit
import Combine
import os

/// How the updater talks to the user, so tests can stand in for alerts and toasts.
@MainActor
protocol UpdatePresenting {
    func promptToInstall(_ offer: UpdateOffer, currentVersion: String) -> UpdatePromptChoice
    /// A quiet note that an update was found by an automatic check; `open` shows the prompt.
    func announce(_ offer: UpdateOffer, open: @escaping @MainActor () -> Void)
    func showUpToDate(currentVersion: String)
    func showError(title: String, message: String, releasePage: URL?)
    func showToast(_ message: String, systemImage: String, action: CheeseToast.Action?)
}

/// Keeps Cheese up to date from GitHub Releases: checks at launch and every 12 hours (unless turned
/// off), offers newer versions in the menu and Settings, and replaces Cheese.app in place.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published private(set) var updateAvailable = false
    @Published private(set) var latestVersion = ""
    @Published private(set) var releaseNotes = ""
    @Published private(set) var releaseURL: URL?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var statusMessage = ""
    /// Checks at launch and twice a day. On unless turned off in Settings → General.
    @Published var autoCheckEnabled: Bool {
        didSet {
            guard autoCheckEnabled != oldValue else { return }
            defaults.set(autoCheckEnabled, forKey: PreferenceKey.updaterAutoCheck)
            autoCheckEnabled ? startScheduledChecks() : stopScheduledChecks()
        }
    }

    let currentVersion: String
    private(set) var offer: UpdateOffer?
    private let fetcher: any ReleaseFetching
    private let installer: any UpdateInstalling
    private let presenter: any UpdatePresenting
    private let defaults: UserDefaults
    private let currentApp: URL
    private let permissions: any PermissionChecking
    private let resetPermission: @MainActor (Permission) -> Void
    private let terminate: @MainActor () -> Void
    private var scheduleTask: Task<Void, Never>?
    /// The version an automatic check already told the user about this launch, so it isn't repeated.
    private var announcedVersion: String?

    init(
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        currentApp: URL = Bundle.main.bundleURL,
        fetcher: (any ReleaseFetching)? = nil,
        installer: any UpdateInstalling = SystemUpdateInstaller(),
        presenter: any UpdatePresenting = SystemUpdatePresenter(),
        defaults: UserDefaults = .standard,
        permissions: any PermissionChecking = SystemPermissions(),
        resetPermission: @escaping @MainActor (Permission) -> Void = UpdateService.resetSystemPermission,
        terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.currentVersion = currentVersion
        self.currentApp = currentApp
        self.fetcher = fetcher ?? GitHubReleaseFetcher(currentVersion: currentVersion)
        self.installer = installer
        self.presenter = presenter
        self.defaults = defaults
        self.permissions = permissions
        self.resetPermission = resetPermission
        self.terminate = terminate
        autoCheckEnabled = defaults.object(forKey: PreferenceKey.updaterAutoCheck) as? Bool ?? true
    }

    // MARK: - Lifecycle

    /// Called once after launch: reports how the last update went, tidies permissions after an
    /// upgrade, and starts the automatic checks.
    func configureOnLaunch(firstCheckDelay: Duration = .seconds(3)) {
        handleLaunchAfterUpdate()
        guard autoCheckEnabled else { return }
        startScheduledChecks(firstCheckDelay: firstCheckDelay)
    }

    /// A check now (after `firstCheckDelay`, so launch isn't slowed), then one whenever 12 hours have
    /// passed since the last, looked at hourly so a Mac that slept through the time catches up.
    func startScheduledChecks(firstCheckDelay: Duration = .zero) {
        stopScheduledChecks()
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: firstCheckDelay)
            await self?.checkForUpdates(userInitiated: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60 * 60))
                guard !Task.isCancelled, let self else { return }
                if UpdatePlanner.isCheckDue(lastCheck: self.lastCheck, now: .now) {
                    await self.checkForUpdates(userInitiated: false)
                }
            }
        }
    }

    func stopScheduledChecks() {
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    private var lastCheck: Date? {
        (defaults.object(forKey: PreferenceKey.updaterLastCheck) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    // MARK: - Checking

    /// Asks GitHub for the newest release. Asked for by the user, it always answers (prompt,
    /// "up to date" or the error); automatic checks only put a toast up for a new, unskipped version.
    func checkForUpdates(userInitiated: Bool = true) async {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        statusMessage = "Checking for updates…"
        defer { isChecking = false }

        let release: GitHubRelease
        do {
            release = try await fetcher.latestRelease()
        } catch {
            Logger.update.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Couldn't check for updates"
            if userInitiated {
                presenter.showError(title: "Couldn't Check for Updates", message: error.localizedDescription, releasePage: nil)
            }
            return
        }
        defaults.set(Date.now.timeIntervalSince1970, forKey: PreferenceKey.updaterLastCheck)

        guard let offer = UpdatePlanner.offer(from: release, currentVersion: currentVersion) else {
            clearOffer()
            statusMessage = "Cheese \(currentVersion) is the newest version"
            Logger.update.notice("Up to date at \(self.currentVersion, privacy: .public) (latest \(release.tagName, privacy: .public))")
            if userInitiated {
                presenter.showUpToDate(currentVersion: currentVersion)
            }
            return
        }

        self.offer = offer
        latestVersion = offer.version
        releaseNotes = offer.notes
        releaseURL = offer.releasePage
        downloadURL = offer.archive
        updateAvailable = true
        statusMessage = "Cheese \(offer.version) is available"
        Logger.update.notice("Update available: \(offer.version, privacy: .public)")

        let skipped = defaults.string(forKey: PreferenceKey.updaterSkippedVersion)
        guard UpdatePlanner.shouldAnnounce(offer, skippedVersion: skipped, announcedVersion: announcedVersion, userInitiated: userInitiated) else { return }
        if userInitiated {
            presentUpdatePrompt()
        } else {
            announcedVersion = offer.version
            presenter.announce(offer) { [weak self] in self?.presentUpdatePrompt() }
        }
    }

    /// The update prompt: Update & Relaunch, Later, or Skip This Version.
    func presentUpdatePrompt() {
        guard let offer, !isInstalling else { return }
        switch presenter.promptToInstall(offer, currentVersion: currentVersion) {
        case .install:
            Task { await downloadAndInstallUpdate() }
        case .skip:
            defaults.set(offer.version, forKey: PreferenceKey.updaterSkippedVersion)
            Logger.update.notice("Skipped \(offer.version, privacy: .public)")
        case .later:
            break
        }
    }

    // MARK: - Installing

    /// Downloads the update, checks it, and hands it to the swap script, then quits so the script
    /// can replace Cheese.app and reopen it. Nothing is touched until the download has passed every check.
    func downloadAndInstallUpdate() async {
        guard let offer, !isInstalling else { return }
        if let problem = installLocationProblem() {
            presenter.showError(title: problem.title, message: problem.message, releasePage: offer.releasePage)
            return
        }
        isInstalling = true
        statusMessage = "Downloading Cheese \(offer.version)…"
        presenter.showToast("Downloading Cheese \(offer.version)…", systemImage: "arrow.down.circle", action: nil)
        Logger.update.notice("Installing \(offer.version, privacy: .public) over \(self.currentApp.path, privacy: .public)")
        do {
            let staged = try await installer.stage(offer, replacing: currentApp)
            statusMessage = "Relaunching Cheese…"
            try installer.launchSwap(staged, replacing: currentApp)
            defaults.set(offer.version, forKey: PreferenceKey.updaterPendingVersion)
            terminate()
        } catch {
            Logger.update.error("Update failed: \(error.localizedDescription, privacy: .public)")
            isInstalling = false
            statusMessage = "The update couldn't be installed"
            presenter.showError(title: "Couldn't Install the Update", message: error.localizedDescription, releasePage: offer.releasePage)
        }
    }

    private func installLocationProblem() -> InstallLocationProblem? {
        let fileManager = FileManager.default
        let folder = currentApp.deletingLastPathComponent()
        let readOnly = (try? currentApp.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return UpdatePlanner.installLocationProblem(
            bundlePath: currentApp.path,
            isOnReadOnlyVolume: readOnly,
            isFolderWritable: fileManager.isWritableFile(atPath: folder.path),
            isBundleWritable: fileManager.isWritableFile(atPath: currentApp.path)
        )
    }

    private func clearOffer() {
        offer = nil
        updateAvailable = false
        latestVersion = ""
        releaseNotes = ""
        releaseURL = nil
        downloadURL = nil
    }

    // MARK: - After an update

    private func handleLaunchAfterUpdate() {
        let previous = defaults.string(forKey: PreferenceKey.updaterLastLaunchedVersion)
        defaults.set(currentVersion, forKey: PreferenceKey.updaterLastLaunchedVersion)

        let pending = defaults.string(forKey: PreferenceKey.updaterPendingVersion)
        defaults.removeObject(forKey: PreferenceKey.updaterPendingVersion)
        switch UpdatePlanner.launchResult(currentVersion: currentVersion, pendingVersion: pending) {
        case let .installed(version):
            presenter.showToast("Updated to Cheese \(version)", systemImage: "sparkles", action: nil)
        case let .failed(version):
            let page = UpdatePlanner.releasesPage
            presenter.showToast("Cheese \(version) couldn't be installed", systemImage: "exclamationmark.triangle.fill", action: page.map { url in
                CheeseToast.Action(title: "Download") { NSWorkspace.shared.open(url) }
            })
        case nil:
            break
        }

        guard UpdatePlanner.isFirstLaunchAfterUpgrade(previousVersion: previous, currentVersion: currentVersion) else { return }
        defaults.removeObject(forKey: PreferenceKey.updaterSkippedVersion)
        Logger.update.notice("First launch of \(self.currentVersion, privacy: .public) after \(previous ?? "?", privacy: .public)")
        // A grant tied to an older binary can show as on in System Settings while the check says no.
        // Removing that stale entry lets the next request add a working one; with nothing granted,
        // there's nothing to remove.
        for permission in [Permission.accessibility, .screenRecording] where !permissions.isGranted(permission) {
            resetPermission(permission)
        }
    }

    /// `tccutil reset <service> com.maanitgupta.cheese`, off the main actor.
    static func resetSystemPermission(_ permission: Permission) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let service = switch permission {
        case .accessibility: "Accessibility"
        case .screenRecording: "ScreenCapture"
        }
        Task.detached(priority: .utility) {
            do {
                try SystemUpdateInstaller.run("/usr/bin/tccutil", ["reset", service, bundleID])
                Logger.update.notice("Reset stale \(service, privacy: .public) entry after the update")
            } catch {
                Logger.update.error("tccutil reset \(service, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// For the spec's version checks: `isVersion("v2.4", newerThan: "2.3")`.
    nonisolated static func isVersion(_ remote: String, newerThan local: String) -> Bool {
        UpdatePlanner.isVersion(remote, newerThan: local)
    }
}

/// Alerts for answers the user asked for, a toast for what automatic checks find.
@MainActor
struct SystemUpdatePresenter: UpdatePresenting {
    func promptToInstall(_ offer: UpdateOffer, currentVersion: String) -> UpdatePromptChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Cheese \(offer.version) is available"
        var details = "You have Cheese \(currentVersion). Cheese downloads the update, checks it, and reopens by itself."
        if !offer.notes.isEmpty {
            details += "\n\n" + offer.notes
        }
        alert.informativeText = details
        alert.addButton(withTitle: "Update & Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .install
        case .alertThirdButtonReturn: return .skip
        default: return .later
        }
    }

    func announce(_ offer: UpdateOffer, open: @escaping @MainActor () -> Void) {
        CheeseToast.show("Cheese \(offer.version) is available", systemImage: "sparkles", action: CheeseToast.Action(title: "Update…", perform: open))
    }

    func showUpToDate(currentVersion: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Cheese is up to date"
        alert.informativeText = "Cheese \(currentVersion) is the newest version."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    func showError(title: String, message: String, releasePage: URL?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        let page = releasePage ?? UpdatePlanner.releasesPage
        if page != nil {
            alert.addButton(withTitle: "Download Manually")
        }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn, let page {
            NSWorkspace.shared.open(page)
        }
    }

    func showToast(_ message: String, systemImage: String, action: CheeseToast.Action?) {
        CheeseToast.show(message, systemImage: systemImage, action: action)
    }
}
