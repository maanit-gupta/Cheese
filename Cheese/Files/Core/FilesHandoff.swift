import Foundation

/// How the Finder extension hands a job to Cheese: it writes `{tool, fileURLs}` as JSON into the
/// shared App Group container and opens `cheese://job/<uuid>`; Cheese reads the file, deletes it
/// and opens the tool. Shared with the Finder extension, so it stays Foundation-only.
enum FilesHandoff {
    struct Job: Codable, Equatable, Sendable {
        var tool: ToolID
        var fileURLs: [URL]
    }

    static let urlScheme = "cheese"
    private static let jobHost = "job"
    /// Shared defaults key the app keeps in step with the Files module toggle.
    static let enabledKey = "filesEnabled"

    /// The team-prefixed App Group, from the `CheeseAppGroup` Info.plist key both targets set.
    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "CheeseAppGroup") as? String
    }

    static var container: URL? {
        appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static var sharedDefaults: UserDefaults? {
        appGroup.flatMap(UserDefaults.init(suiteName:))
    }

    /// Whether the Files module is on, as last mirrored by the app. On until the app says otherwise.
    static var isEnabled: Bool {
        sharedDefaults?.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool) {
        guard let defaults = sharedDefaults, defaults.object(forKey: enabledKey) as? Bool != enabled else { return }
        defaults.set(enabled, forKey: enabledKey)
    }

    static func url(for id: UUID) -> URL? {
        URL(string: "\(urlScheme)://\(jobHost)/\(id.uuidString)")
    }

    /// The job ID in `cheese://job/<uuid>`, or nil for any other URL.
    static func jobID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == urlScheme, url.host()?.lowercased() == jobHost else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, let first = parts.first else { return nil }
        return UUID(uuidString: first)
    }

    static func jobsFolder(in container: URL) -> URL {
        container.appending(path: "Jobs", directoryHint: .isDirectory)
    }

    static func write(_ job: Job, to container: URL) throws -> UUID {
        let id = UUID()
        let folder = jobsFolder(in: container)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: folder.appending(path: "\(id.uuidString).json"), options: .atomic)
        return id
    }

    /// Reads a job and deletes its file, so each job runs once.
    static func consume(_ id: UUID, from container: URL) throws -> Job {
        let file = jobsFolder(in: container).appending(path: "\(id.uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        return try JSONDecoder().decode(Job.self, from: Data(contentsOf: file))
    }
}
