import AVFoundation
import AppKit
import FinderSync
import UserNotifications

/// Live status of each `PermissionNeed`, and how to grant it. Shared by the welcome screen and Settings.
@MainActor
@Observable
final class PermissionStatus {
    enum State: Equatable {
        case granted
        case missing
        /// macOS offers no way to check (Local Network); it asks on first use.
        case unknown
    }

    private(set) var states: [PermissionNeed: State] = [:]
    private let permissions: any PermissionChecking
    private let openPermissionSettings: @MainActor (Permission) -> Void

    init(permissions: any PermissionChecking, openPermissionSettings: @escaping @MainActor (Permission) -> Void) {
        self.permissions = permissions
        self.openPermissionSettings = openPermissionSettings
    }

    func state(of need: PermissionNeed) -> State {
        states[need] ?? .unknown
    }

    func refresh() async {
        var states: [PermissionNeed: State] = [:]
        for need in PermissionNeed.allCases {
            switch need {
            case .screenRecording, .accessibility:
                if let permission = need.permission {
                    states[need] = permissions.isGranted(permission) ? .granted : .missing
                }
            case .notifications:
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                states[need] = [.authorized, .provisional].contains(settings.authorizationStatus) ? .granted : .missing
            case .localNetwork:
                states[need] = .unknown
            case .finderExtension:
                states[need] = FIFinderSyncController.isExtensionEnabled ? .granted : .missing
            case .camera, .microphone:
                states[need] = AVCaptureDevice.authorizationStatus(for: Self.mediaType(need)) == .authorized ? .granted : .missing
            }
        }
        self.states = states
    }

    /// Polls once a second while `isActive`, so statuses update while the user is in System Settings.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func grant(_ need: PermissionNeed) {
        switch need {
        case .screenRecording, .accessibility:
            if let permission = need.permission {
                openPermissionSettings(permission)
            }
        case .notifications:
            Task {
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    _ = try? await center.requestAuthorization(options: [.alert, .sound])
                } else if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")") {
                    NSWorkspace.shared.open(url)
                }
                await refresh()
            }
        case .localNetwork:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                NSWorkspace.shared.open(url)
            }
        case .finderExtension:
            FIFinderSyncController.showExtensionManagementInterface()
        case .camera, .microphone:
            let type = Self.mediaType(need)
            Task {
                if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: type)
                } else {
                    MediaPrivacy.openSettings(for: type)
                }
                await refresh()
            }
        }
    }

    private static func mediaType(_ need: PermissionNeed) -> AVMediaType {
        need == .camera ? .video : .audio
    }
}
