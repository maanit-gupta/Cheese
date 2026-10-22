import AppKit
import UserNotifications
import os

/// Cheese's user notifications (finished Files jobs, received Share files), asking permission the
/// first time one is posted. "Show in Finder" (or clicking the notification) reveals the files.
/// One shared instance, because it's the notification center's delegate.
@MainActor
final class CheeseNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CheeseNotifications()

    // The identifier predates Share; kept so notifications already delivered still get the action.
    private nonisolated static let categoryID = "filesJobDone"
    private nonisolated static let showInFinderID = "showInFinder"
    private nonisolated static let outputsKey = "outputs"
    private var isConfigured = false

    func post(id: String = UUID().uuidString, title: String, body: String, reveal files: [URL]) {
        let center = UNUserNotificationCenter.current()
        configure(center)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [Self.outputsKey: files.map { $0.path(percentEncoded: false) }]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            do {
                // Asks only while the status is undetermined, which makes this the first notification.
                let settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                }
                try await center.add(request)
            } catch {
                Logger.core.error("Couldn't post a notification: \(error.localizedDescription, privacy: .public)")
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
