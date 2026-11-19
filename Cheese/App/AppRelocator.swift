import AppKit
import os

/// Moves a downloaded Cheese into `/Applications/Cheese.app`, sends stray copies to the Trash and
/// relaunches the installed copy, so testers never end up with several copies or two menu bar icons.
/// Runs from `applicationWillFinishLaunching`, before any status item, hotkey or window exists.
/// `AppRelocationPlanner` makes every decision; this type only gathers facts and acts on them.
@MainActor
enum AppRelocator {
    /// Returns true when this process is handing over to another copy and must not set anything up.
    static func relocateIfNeeded() -> Bool {
        let bundle = Bundle.main
        guard let bundleID = bundle.bundleIdentifier else { return false }
        let fileManager = FileManager.default
        let currentURL = bundle.bundleURL.resolvingSymlinksInPath()
        let targetURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(bundle.bundleURL.lastPathComponent.hasSuffix(".app")
                ? bundle.bundleURL.lastPathComponent : "Cheese.app")
        let home = fileManager.homeDirectoryForCurrentUser
        let cleanupFolders = [
            home.appendingPathComponent("Downloads"), home.appendingPathComponent("Desktop"),
            URL(fileURLWithPath: "/Applications"),
        ]
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }

        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif

        let input = AppRelocationPlanner.Input(
            currentPath: currentURL.path,
            translocatedOriginalPath: translocatedOriginal(of: currentURL)?.path,
            currentVersion: version(of: currentURL),
            targetPath: targetURL.path,
            installed: fileManager.fileExists(atPath: targetURL.path)
                ? AppBundleCandidate(path: targetURL.path, version: version(of: targetURL)) : nil,
            canWriteTarget: fileManager.isWritableFile(atPath: targetURL.deletingLastPathComponent().path),
            cleanupFolders: cleanupFolders.map(\.path),
            candidates: candidates(bundleID: bundleID, in: cleanupFolders),
            runningPaths: others.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path },
            isDebugBuild: isDebugBuild,
            isRunningTests: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            wasRelaunched: CommandLine.arguments.contains(AppRelocationPlanner.relaunchArgument)
        )

        switch AppRelocationPlanner.plan(input) {
        case .none:
            return false
        case .cleanUp(let trash):
            moveToTrash(trash)
            return false
        case .openInstalled(let trash):
            Logger.app.notice("A newer Cheese is in Applications; opening it instead of \(currentURL.path, privacy: .public)")
            relaunch(targetURL, thenTrash: trash)
            return true
        case .relocate(let trash):
            terminate(others)
            guard install(currentURL, at: targetURL) else { return false }
            relaunch(targetURL, thenTrash: trash)
            return true
        }
    }

    // MARK: - Facts

    private static func version(of bundleURL: URL) -> AppVersion? {
        guard let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")),
              let short = info["CFBundleShortVersionString"] as? String else { return nil }
        return AppVersion(short)
    }

    private static func bundleIdentifier(of bundleURL: URL) -> String? {
        NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
    }

    /// Cheese bundles directly inside the cleanup folders, plus every one Launch Services knows of
    /// (the planner drops those outside the cleanup folders).
    private static func candidates(bundleID: String, in folders: [URL]) -> [AppBundleCandidate] {
        var urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            urls += items.filter { $0.pathExtension == "app" && bundleIdentifier(of: $0) == bundleID }
        }
        return urls.map { url in
            let resolved = url.resolvingSymlinksInPath()
            return AppBundleCandidate(path: resolved.path, version: version(of: resolved))
        }
    }

    /// The real location of a bundle macOS is running from a read-only App Translocation mount, via
    /// Security.framework's `SecTranslocateCreateOriginalPathForURL` (looked up at run time; it has no
    /// public header). `nil` when the bundle isn't translocated or the lookup isn't available.
    private static func translocatedOriginal(of url: URL) -> URL? {
        guard AppRelocationPlanner.isTranslocated(url.path),
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        typealias CreateOriginal = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let createOriginal = unsafeBitCast(symbol, to: CreateOriginal.self)
        guard let original = createOriginal(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return (original as URL).resolvingSymlinksInPath()
    }

    // MARK: - Actions

    /// Asks other running copies to quit, waits up to 2 s, then force-quits whatever is left.
    private static func terminate(_ apps: [NSRunningApplication]) {
        guard !apps.isEmpty else { return }
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, apps.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for app in apps where !app.isTerminated {
            Logger.app.notice("Force-quitting the other running Cheese (pid \(app.processIdentifier))")
            app.forceTerminate()
        }
        // Give a force-quit process a moment to go so its bundle can be replaced.
        let grace = Date().addingTimeInterval(0.5)
        while Date() < grace, apps.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Copies the bundle next to the target first and swaps it in only once the copy is complete, so a
    /// failed copy never leaves `/Applications` without Cheese.
    private static func install(_ source: URL, at target: URL) -> Bool {
        let fileManager = FileManager.default
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".Cheese-relocating-\(UUID().uuidString).app")
        do {
            try fileManager.copyItem(at: source, to: staging)
            removeQuarantine(staging)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: target)
            }
        } catch {
            Logger.app.error("Couldn't move Cheese into Applications: \(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: staging)
            return false
        }
        guard bundleIdentifier(of: target) == Bundle.main.bundleIdentifier,
              fileManager.isExecutableFile(atPath: target.appendingPathComponent("Contents/MacOS/Cheese").path) else {
            Logger.app.error("The copy in Applications looks incomplete; not cleaning up or relaunching")
            return false
        }
        Logger.app.notice("Moved Cheese from \(source.path, privacy: .public) to \(target.path, privacy: .public)")
        return true
    }

    /// A copied download keeps its quarantine flag, and a quarantined copy would be translocated again.
    private static func removeQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Logger.app.error("Couldn't clear quarantine: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func moveToTrash(_ paths: [String]) {
        for path in paths {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                Logger.app.notice("Moved duplicate Cheese to the Trash: \(path, privacy: .public)")
            } catch {
                Logger.app.error("Couldn't trash duplicate \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Opens the installed copy and quits; the duplicates go to the Trash only once it has launched.
    private static func relaunch(_ target: URL, thenTrash trash: [String]) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [AppRelocationPlanner.relaunchArgument]
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, error in
            let failure = error?.localizedDescription
            DispatchQueue.main.async {
                if let failure {
                    Logger.app.error("Couldn't open \(target.path, privacy: .public): \(failure, privacy: .public)")
                } else {
                    moveToTrash(trash)
                }
                NSApp.terminate(nil)
            }
        }
    }
}
