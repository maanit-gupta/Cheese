import Foundation

/// How the macOS Share menu extension hands things to Cheese Share: it copies them into a job folder
/// in the App Group container (files as files, text and links in `job.json`) and opens
/// `cheese://share/<uuid>`; Cheese opens the Share panel with them ready to send. Shared with the
/// extension, so it stays Foundation-only. The container helpers are `FilesHandoff`'s.
enum ShareHandoff {
    struct Job: Codable, Equatable, Sendable {
        /// File names inside the job folder.
        var files: [String]
        var texts: [String]
    }

    static let host = "share"
    /// Shared defaults key the app keeps in step with the Share module toggle.
    static let enabledKey = "shareEnabled"

    static var isEnabled: Bool {
        FilesHandoff.sharedDefaults?.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool) {
        guard let defaults = FilesHandoff.sharedDefaults, defaults.object(forKey: enabledKey) as? Bool != enabled else { return }
        defaults.set(enabled, forKey: enabledKey)
    }

    static func url(for id: UUID) -> URL? {
        URL(string: "\(FilesHandoff.urlScheme)://\(host)/\(id.uuidString)")
    }

    /// `cheese://settings/share`, which the extension opens when Share is off.
    static var settingsURL: URL? {
        URL(string: "\(FilesHandoff.urlScheme)://settings/share")
    }

    /// The job ID in `cheese://share/<uuid>`, or nil for any other URL.
    static func jobID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == FilesHandoff.urlScheme, url.host()?.lowercased() == host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, let first = parts.first else { return nil }
        return UUID(uuidString: first)
    }

    static func jobsFolder(in container: URL) -> URL {
        container.appending(path: "ShareJobs", directoryHint: .isDirectory)
    }

    static func folder(for id: UUID, in container: URL) -> URL {
        jobsFolder(in: container).appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// Starts a job: an empty folder the extension copies files into, then `finish`es.
    static func makeJob(in container: URL) throws -> (id: UUID, folder: URL) {
        let id = UUID()
        let folder = folder(for: id, in: container)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (id, folder)
    }

    static func finish(_ job: Job, in folder: URL) throws {
        try JSONEncoder().encode(job).write(to: folder.appending(path: "job.json"), options: .atomic)
    }

    /// The job's files (inside its folder, where they stay until Cheese Share stops) and texts.
    static func read(_ id: UUID, from container: URL) throws -> (files: [URL], texts: [String]) {
        let folder = folder(for: id, in: container)
        let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: folder.appending(path: "job.json")))
        let files = job.files
            .filter { !$0.contains("/") && !$0.hasPrefix(".") && $0 != "job.json" }
            .map { folder.appending(path: $0, directoryHint: .notDirectory) }
        return (files, job.texts)
    }

    /// Deletes every handed-over job, once nothing can still be sending them.
    static func removeAll(in container: URL) {
        try? FileManager.default.removeItem(at: jobsFolder(in: container))
    }
}
