import Foundation
import Synchronization

/// One file a job couldn't process, and why. An empty `file` means the whole job failed.
struct JobFailure: Sendable, Equatable {
    var file: String
    var reason: String
}

/// What a finished job produced, for the notification.
struct JobReport: Sendable {
    var id: UUID
    var tool: ToolID
    var inputs: [URL]
    var outputs: [URL]
    var failures: [JobFailure]
    /// Extra lines for the notification, like "Couldn't reach 2 MB — smallest possible is 3.4 MB".
    var notes: [String]
    /// Some output went to ~/Downloads because the original's folder wasn't writable.
    var wroteToDownloads: Bool
    var wasCancelled: Bool
}

/// A unit of work for `JobQueue`: one tool run over its input files.
struct JobWork: Sendable {
    var tool: ToolID
    var inputs: [URL]
    /// Progress units, one per input file unless the tool says otherwise.
    var total: Int
    var run: @Sendable (JobContext) async throws -> Void

    init(tool: ToolID, inputs: [URL], total: Int? = nil, run: @escaping @Sendable (JobContext) async throws -> Void) {
        self.tool = tool
        self.inputs = inputs
        self.total = total ?? inputs.count
        self.run = run
    }

    /// Runs `process` on each input in order. A file that fails is reported and the rest carry on.
    static func perFile(
        tool: ToolID,
        inputs: [URL],
        process: @escaping @Sendable (URL, JobContext) async throws -> Void
    ) -> JobWork {
        JobWork(tool: tool, inputs: inputs) { context in
            for input in inputs {
                try Task.checkCancellation()
                do {
                    try await process(input, context)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    context.fail(input, error)
                }
                context.fileFinished()
            }
        }
    }
}

/// A job's view of the file system and its progress. Hands out output URLs (next to the original,
/// never overwriting, falling back to ~/Downloads), and remembers them so a cancelled or failed
/// file leaves nothing behind.
final class JobContext: Sendable {
    let tool: ToolID
    private let fallbackFolder: URL
    private let onProgress: @Sendable (Int) -> Void
    private let isWritable: @Sendable (URL) -> Bool
    private let state = Mutex(State())

    private struct State {
        var outputs: [(input: URL?, url: URL)] = []
        var reserved: Set<URL> = []
        var failures: [JobFailure] = []
        var notes: [String] = []
        var completed = 0
        var wroteToDownloads = false
    }

    init(
        tool: ToolID,
        fallbackFolder: URL = .downloadsDirectory,
        isWritable: @escaping @Sendable (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path(percentEncoded: false)) },
        onProgress: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.tool = tool
        self.fallbackFolder = fallbackFolder
        self.isWritable = isWritable
        self.onProgress = onProgress
    }

    /// The folder outputs for `input` go into: its own folder, or ~/Downloads if that isn't writable.
    func folder(for input: URL) -> URL {
        let original = input.deletingLastPathComponent()
        if isWritable(original) {
            return original
        }
        state.withLock { $0.wroteToDownloads = true }
        return fallbackFolder
    }

    /// Reserves an output file for `input`: `Report (compressed).pdf`, or `Report.docx` when `suffix` is nil.
    func outputURL(for input: URL, suffix: String?, extension ext: String) -> URL {
        let folder = folder(for: input)
        return state.withLock { state in
            let url = OutputNamer.output(for: input, suffix: suffix, extension: ext, in: folder) { candidate in
                state.reserved.contains(candidate) || FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false))
            }
            state.reserved.insert(url)
            state.outputs.append((input, url))
            return url
        }
    }

    /// Creates an output folder for `input`, like `Report (images)`, for tools that write several files.
    func outputFolder(for input: URL, suffix: String) throws -> URL {
        let parent = folder(for: input)
        let name = "\(OutputNamer.baseName(of: input)) (\(suffix))"
        let url = state.withLock { state in
            let url = OutputNamer.uniqueFolder(named: name, in: parent) { candidate in
                state.reserved.contains(candidate) || FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false))
            }
            state.reserved.insert(url)
            state.outputs.append((input, url))
            return url
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Records a file that failed and removes whatever was written for it.
    func fail(_ input: URL, _ error: any Error) {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let leftovers = state.withLock { state in
            state.failures.append(JobFailure(file: input.lastPathComponent, reason: reason))
            let mine = state.outputs.filter { $0.input == input }.map(\.url)
            state.outputs.removeAll { $0.input == input }
            return mine
        }
        Self.remove(leftovers)
    }

    /// Records that the whole job failed (for tools that combine their inputs into one output).
    func failAll(_ error: any Error) {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        state.withLock { $0.failures.append(JobFailure(file: "", reason: reason)) }
        discardOutputs()
    }

    func note(_ text: String) {
        state.withLock { $0.notes.append(text) }
    }

    /// Forgets an output that was reserved but not written, like a compressed copy that came out bigger.
    func discard(_ url: URL) {
        state.withLock { $0.outputs.removeAll { $0.url == url } }
        Self.remove([url])
    }

    func fileFinished() {
        let completed = state.withLock { state in
            state.completed += 1
            return state.completed
        }
        onProgress(completed)
    }

    /// Deletes everything this job wrote. Used when it's cancelled.
    func discardOutputs() {
        let all = state.withLock { state in
            let urls = state.outputs.map(\.url)
            state.outputs.removeAll()
            return urls
        }
        Self.remove(all)
    }

    func report(id: UUID, inputs: [URL], wasCancelled: Bool) -> JobReport {
        state.withLock { state in
            JobReport(
                id: id, tool: tool, inputs: inputs,
                // Outputs that were reserved but never written (a skipped file) aren't reported.
                outputs: state.outputs.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) },
                failures: state.failures, notes: state.notes,
                wroteToDownloads: state.wroteToDownloads, wasCancelled: wasCancelled
            )
        }
    }

    private static func remove(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
