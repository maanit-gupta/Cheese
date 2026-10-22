import Foundation

struct InstalledApp: Identifiable, Hashable, Sendable {
    var bundleID: String
    var name: String
    var url: URL

    var id: String { bundleID }
}

/// The apps in the usual Applications folders, scanned in the background and cached.
actor InstalledAppIndex {
    static let maxAge: Duration = .seconds(10 * 60)

    static var searchFolders: [URL] {
        [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            URL(filePath: "/Applications/Utilities", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications/Utilities", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    private let folders: [URL]
    private var cache: [InstalledApp] = []
    private var scannedAt: ContinuousClock.Instant?

    init(folders: [URL] = InstalledAppIndex.searchFolders) {
        self.folders = folders
    }

    /// The cached list, rescanned first when it's missing or older than `maxAge`.
    func apps(maxAge: Duration = InstalledAppIndex.maxAge) -> [InstalledApp] {
        if let scannedAt, ContinuousClock.now - scannedAt < maxAge {
            return cache
        }
        cache = Self.scan(folders)
        scannedAt = .now
        return cache
    }

    /// Apps directly in each folder, plus one level into plain subfolders (vendor folders like
    /// "Microsoft Office"). The first copy of a bundle ID wins. Sorted by name.
    static func scan(_ folders: [URL]) -> [InstalledApp] {
        let fileManager = FileManager.default
        var seen: Set<String> = []
        var apps: [InstalledApp] = []

        func contents(of folder: URL) -> [URL] {
            (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        func add(_ url: URL) {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier, seen.insert(bundleID).inserted else { return }
            apps.append(InstalledApp(bundleID: bundleID, name: url.deletingPathExtension().lastPathComponent, url: url))
        }

        for folder in folders {
            for url in contents(of: folder) {
                if url.pathExtension == "app" {
                    add(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    for nested in contents(of: url) where nested.pathExtension == "app" {
                        add(nested)
                    }
                }
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
