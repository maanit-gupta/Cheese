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

/// Posts a notification when a job finishes, asking permission the first time.
/// "Show in Finder" (or clicking the notification) reveals the outputs.
@MainActor
final class JobNotifications: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let categoryID = "filesJobDone"
    private nonisolated static let showInFinderID = "showInFinder"
    private nonisolated static let outputsKey = "outputs"
    private var isConfigured = false

    func post(_ report: JobReport) {
        guard !report.wasCancelled else { return }
        let center = UNUserNotificationCenter.current()
        configure(center)
        let summary = JobSummary(report: report)
        let content = UNMutableNotificationContent()
        content.title = summary.title
        content.body = summary.body
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [Self.outputsKey: report.outputs.map { $0.path(percentEncoded: false) }]
        let request = UNNotificationRequest(identifier: report.id.uuidString, content: content, trigger: nil)
        Task {
            do {
                // Asks only while the status is undetermined, which makes this the first finished job.
                let settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                }
                try await center.add(request)
            } catch {
                Logger.files.error("Couldn't post the job notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func configure(_ center: UNUserNotificationCenter) {
        guard !isConfigured else { return }
        isConfigured = true
        center.delegate = self
        let show = UNNotificationAction(identifier: Self.showInFinderID, title: "Show in Finder")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryID, actions: [show], intentIdentifiers: [])])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let paths = response.notification.request.content.userInfo[Self.outputsKey] as? [String] ?? []
        let action = response.actionIdentifier
        guard action == Self.showInFinderID || action == UNNotificationDefaultActionIdentifier, !paths.isEmpty else { return }
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0) })
        }
    }
}
