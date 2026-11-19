import Foundation

/// What a launch should do about where Cheese lives (pure; `AppRelocator` carries it out).
enum AppRelocationAction: Equatable {
    /// Leave everything as it is.
    case none
    /// Already in place: only move stray copies to the Trash.
    case cleanUp(trash: [String])
    /// Copy this bundle over the installed one, move stray copies to the Trash, relaunch the installed copy.
    case relocate(trash: [String])
    /// The installed copy is newer than this one: open it instead and move this (older) copy to the Trash.
    case openInstalled(trash: [String])
}

/// A `.app` bundle found on disk whose bundle identifier is Cheese's.
struct AppBundleCandidate: Equatable {
    let path: String
    let version: AppVersion?
}

/// Decides whether this launch moves Cheese into `/Applications` and which duplicate copies go to the Trash.
///
/// Duplicates are only ever looked for in places a downloaded copy ends up (directly inside the home
/// folder's Downloads and Desktop, and `/Applications`) plus the folder a translocated copy was opened
/// from. Build products (DerivedData, `Build/Products`, the repo's `build/` and `dist/`) are never
/// touched, and neither is a copy that's running.
enum AppRelocationPlanner {
    static let relaunchArgument = "--cheese-relocated"

    struct Input {
        /// The running bundle, symlinks resolved.
        var currentPath: String
        /// Where the running bundle really is when macOS translocated it (`nil` if it wasn't).
        var translocatedOriginalPath: String?
        var currentVersion: AppVersion?
        /// `/Applications/Cheese.app`.
        var targetPath: String
        /// The copy at `targetPath`, if there is one.
        var installed: AppBundleCandidate?
        var canWriteTarget: Bool
        /// Folders a stray copy may sit in directly (Downloads, Desktop, /Applications).
        var cleanupFolders: [String]
        /// Every bundle with Cheese's identifier that was found (scans + Launch Services).
        var candidates: [AppBundleCandidate]
        /// Bundles of other running Cheese processes.
        var runningPaths: [String]
        var isDebugBuild: Bool
        var isRunningTests: Bool
        var wasRelaunched: Bool
    }

    static func plan(_ input: Input) -> AppRelocationAction {
        guard !input.isDebugBuild, !input.isRunningTests, !isDevelopmentBuild(input.currentPath) else { return .none }
        let current = standardized(input.currentPath)
        let target = standardized(input.targetPath)
        let isAtTarget = current == target

        if isAtTarget {
            let trash = duplicates(input, keeping: target, alsoTrash: [])
            return trash.isEmpty ? .none : .cleanUp(trash: trash)
        }
        // A relaunched copy that still isn't in place must not try again (no relaunch loops).
        guard !input.wasRelaunched else { return .none }

        // The copy the user opened: the real folder for a translocated launch, otherwise the bundle itself.
        let original = input.translocatedOriginalPath.map(standardized) ?? (isTranslocated(current) ? nil : current)
        let opened = original.flatMap { isDevelopmentBuild($0) ? nil : $0 }.map { [$0] } ?? []

        if let installed = input.installed, let installedVersion = installed.version,
           let currentVersion = input.currentVersion, installedVersion > currentVersion {
            return .openInstalled(trash: duplicates(input, keeping: target, alsoTrash: opened))
        }
        guard input.canWriteTarget else { return .none }
        return .relocate(trash: duplicates(input, keeping: target, alsoTrash: opened))
    }

    /// Xcode and repo build products: never moved, never trashed.
    static func isDevelopmentBuild(_ path: String) -> Bool {
        let markers = ["/DerivedData/", "/Build/Products/", "/build/ReleaseData/", "/build/SizeCheck/", "/dist/"]
        return markers.contains { path.contains($0) }
    }

    static func isTranslocated(_ path: String) -> Bool { path.contains("/AppTranslocation/") }

    private static func duplicates(_ input: Input, keeping target: String, alsoTrash extra: [String]) -> [String] {
        let folders = Set(input.cleanupFolders.map(standardized))
        let running = Set(input.runningPaths.map(standardized))
        var seen = Set<String>()
        var result: [String] = []
        let paths = input.candidates.map { standardized($0.path) } + extra
        for path in paths where seen.insert(path).inserted {
            guard path != target, !running.contains(path), !isTranslocated(path), !isDevelopmentBuild(path),
                  !path.contains("/.Trash/") else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            guard folders.contains(folder) || extra.contains(path) else { continue }
            result.append(path)
        }
        return result
    }

    private static func standardized(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        // /private/var/... and /var/... are the same folder; compare one spelling.
        if path.hasPrefix("/private/var/") { path = String(path.dropFirst("/private".count)) }
        return path
    }
}
