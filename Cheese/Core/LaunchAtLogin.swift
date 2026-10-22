import ServiceManagement

@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// System Settings → General → Login Items, where a login item waiting for approval is turned on.
    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
