import Foundation
import os

/// Runs Files jobs: at most two at once, the rest wait their turn. Each job processes its files
/// in order. Reports progress for the menu bar and a `JobReport` when a job ends.
actor JobQueue {
    struct Status: Sendable, Equatable, Identifiable {
        var id: UUID
        var tool: ToolID
        var title: String
        var completed: Int
        var total: Int
        var isRunning: Bool
    }

    nonisolated let maxConcurrent: Int
    private var waiting: [Entry] = []
    private var running: [UUID: Entry] = [:]
    /// Start order, so statuses list oldest first.
    private var order: [UUID] = []
    private let onChange: @Sendable ([Status]) async -> Void
    private let onFinish: @Sendable (JobReport) async -> Void

    private struct Entry {
        var id: UUID
        var work: JobWork
        var context: JobContext
        var title: String
        var completed = 0
        var task: Task<Void, Never>?
    }

    init(
        maxConcurrent: Int = 2,
        onChange: @escaping @Sendable ([Status]) async -> Void,
        onFinish: @escaping @Sendable (JobReport) async -> Void
    ) {
        self.maxConcurrent = maxConcurrent
        self.onChange = onChange
        self.onFinish = onFinish
    }

    /// Queues a job and starts it if a slot is free.
    @discardableResult
    func enqueue(_ work: JobWork, context makeContext: (@Sendable (@escaping @Sendable (Int) -> Void) -> JobContext)? = nil) async -> UUID {
        let id = UUID()
        let onProgress: @Sendable (Int) -> Void = { [weak self] completed in
            Task { await self?.progress(id, completed: completed) }
        }
        let context = makeContext?(onProgress) ?? JobContext(tool: work.tool, onProgress: onProgress)
        let title = JobTitles.inProgress(work.tool, inputs: work.inputs)
        waiting.append(Entry(id: id, work: work, context: context, title: title))
        order.append(id)
        Logger.files.info("Queued \(work.tool.rawValue, privacy: .public) on \(work.inputs.count) file(s)")
        startWaiting()
        await onChange(statuses)
        return id
    }

    /// Cancels a waiting or running job. A running job's partial outputs are deleted.
    func cancel(_ id: UUID) async {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            let entry = waiting.remove(at: index)
            order.removeAll { $0 == id }
            await onChange(statuses)
            await onFinish(entry.context.report(id: id, inputs: entry.work.inputs, wasCancelled: true))
        } else {
            running[id]?.task?.cancel()
        }
    }

    func cancelAll() async {
        for id in order {
            await cancel(id)
        }
    }

    var statuses: [Status] {
        order.compactMap { id in
            if let entry = running[id] {
                return Status(id: id, tool: entry.work.tool, title: entry.title, completed: entry.completed, total: entry.work.total, isRunning: true)
            }
            if let entry = waiting.first(where: { $0.id == id }) {
                return Status(id: id, tool: entry.work.tool, title: entry.title, completed: 0, total: entry.work.total, isRunning: false)
            }
            return nil
        }
    }

    private func startWaiting() {
        while running.count < maxConcurrent, !waiting.isEmpty {
            var entry = waiting.removeFirst()
            let id = entry.id
            let work = entry.work
            let context = entry.context
            // Detached: the work is heavy and must not run on this actor.
            entry.task = Task.detached(priority: .userInitiated) { [weak self] in
                var cancelled = false
                do {
                    try await work.run(context)
                } catch is CancellationError {
                    cancelled = true
                } catch {
                    context.failAll(error)
                }
                cancelled = cancelled || Task.isCancelled
                if cancelled {
                    context.discardOutputs()
                }
                await self?.finished(id, report: context.report(id: id, inputs: work.inputs, wasCancelled: cancelled))
            }
            running[id] = entry
        }
    }

    private func progress(_ id: UUID, completed: Int) async {
        guard var entry = running[id], completed > entry.completed else { return }
        entry.completed = completed
        running[id] = entry
        await onChange(statuses)
    }

    private func finished(_ id: UUID, report: JobReport) async {
        running[id] = nil
        order.removeAll { $0 == id }
        Logger.files.info("Finished \(report.tool.rawValue, privacy: .public): \(report.outputs.count) output(s), \(report.failures.count) failure(s), cancelled: \(report.wasCancelled)")
        startWaiting()
        await onChange(statuses)
        await onFinish(report)
    }
}

/// Short descriptions of a job: "Merging 3 PDFs…", "Merged 3 PDFs", and the menu bar count.
enum JobTitles {
    /// "Report.pdf" for one file, otherwise "3 PDFs", "2 images" or "4 files".
    static func subject(_ inputs: [URL]) -> String {
        if inputs.count == 1, let only = inputs.first {
            return only.lastPathComponent
        }
        let kinds = Set(inputs.map(FileKind.init(url:)))
        let noun: String = switch kinds.count == 1 ? kinds.first : nil {
        case .pdf: "PDFs"
        case .image: "images"
        case .word: "Word documents"
        case .excel: "spreadsheets"
        case .powerPoint: "presentations"
        default: "files"
        }
        return "\(inputs.count) \(noun)"
    }

    static func inProgress(_ tool: ToolID, inputs: [URL]) -> String {
        "\(tool.verbs.present) \(subject(inputs))…"
    }

    static func done(_ tool: ToolID, inputs: [URL]) -> String {
        "\(tool.verbs.past) \(subject(inputs))"
    }

    /// "3/10": files done out of files queued, across every job. Nil when nothing is running.
    static func indicator(_ statuses: [JobQueue.Status]) -> String? {
        guard !statuses.isEmpty else { return nil }
        let completed = statuses.reduce(0) { $0 + $1.completed }
        let total = statuses.reduce(0) { $0 + $1.total }
        return "\(completed)/\(total)"
    }
}
