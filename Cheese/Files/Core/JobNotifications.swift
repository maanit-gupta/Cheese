import AppKit
import UserNotifications
import os

/// What a finished job's notification says. Pure, so the wording is tested.
struct JobSummary: Equatable {
    var title: String
    var body: String

    init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    init(report: JobReport) {
        let succeeded = report.outputs.isEmpty == false
        let failed = report.failures
        if !succeeded, !failed.isEmpty {
            title = "\(report.tool.title) failed"
        } else {
            title = JobTitles.done(report.tool, inputs: report.inputs)
        }

        var lines: [String] = []
        if succeeded, failed.isEmpty {
            let names = report.outputs.map(\.lastPathComponent)
            lines.append(names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) files")
        }
        if !failed.isEmpty {
            if failed.count == 1, let only = failed.first {
                lines.append(only.file.isEmpty ? only.reason : "\(only.file): \(only.reason)")
            } else {
                let total = report.inputs.count
                lines.append("\(failed.count) of \(total) failed:")
                lines += failed.prefix(4).map { $0.file.isEmpty ? $0.reason : "\($0.file): \($0.reason)" }
                if failed.count > 4 {
                    lines.append("…and \(failed.count - 4) more")
                }
            }
        }
        lines += report.notes
        if report.wroteToDownloads {
            lines.append("The original's folder isn't writable, so the result is in Downloads.")
        }
        body = lines.joined(separator: "\n")
    }
}

extension CheeseNotifications {
    /// A finished Files job: what was made and what failed. Cancelled jobs post nothing.
    func post(_ report: JobReport) {
        guard !report.wasCancelled else { return }
        let summary = JobSummary(report: report)
        post(id: report.id.uuidString, title: summary.title, body: summary.body, reveal: report.outputs)
    }
}
