/// Everything a Cheese tool may ask macOS for: the two TCC permissions plus notifications,
/// Local Network and the Finder extension.
enum PermissionNeed: CaseIterable, Identifiable, Sendable {
    case screenRecording
    case accessibility
    case notifications
    case localNetwork
    case finderExtension
    /// Screen recordings with the webcam on.
    case camera
    /// Screen recordings with your voice.
    case microphone

    var id: Self { self }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .notifications: "Notifications"
        case .localNetwork: "Local Network"
        case .finderExtension: "Finder Extension"
        case .camera: "Camera"
        case .microphone: "Microphone"
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .notifications: "bell.badge"
        case .localNetwork: "network"
        case .finderExtension: "folder.badge.gearshape"
        case .camera: "video"
        case .microphone: "mic"
        }
    }

    /// Only needed for an extra the user turns on (the camera or microphone in a recording).
    var isOptional: Bool {
        self == .camera || self == .microphone
    }

    /// The TCC permission behind this need, for the two Cheese can check directly.
    var permission: Permission? {
        switch self {
        case .screenRecording: .screenRecording
        case .accessibility: .accessibility
        case .notifications, .localNetwork, .finderExtension, .camera, .microphone: nil
        }
    }
}

/// Which permissions the tools the user picked need, so the welcome screen asks only for those.
enum PermissionPlan {
    static func needs(of module: ModuleID) -> [PermissionNeed] {
        switch module {
        case .clipboard: [.accessibility]
        case .screenshots, .ocr: [.screenRecording]
        // The camera and microphone only when turned on in the recording bar.
        case .screenRecording: [.screenRecording, .camera, .microphone]
        case .scrollingCapture: [.screenRecording, .accessibility]
        case .windowSnapping: [.accessibility]
        // The zoom lens and snapshots read the screen.
        case .drawOnScreen: [.screenRecording]
        case .files: [.notifications, .finderExtension]
        case .share: [.localNetwork, .notifications]
        // Terminals without AppleScript (Ghostty, VS Code…) are read through Accessibility.
        case .terminalTrace: [.accessibility]
        // Blocking input takes an event tap, which needs Accessibility.
        case .sweep: [.accessibility]
        // Meeting apps' share indicators are found by window title, which needs Screen Recording.
        case .hush: [.screenRecording]
        // Quitting other apps needs no permission.
        case .qr, .keepAwake, .appHotkeys, .commandPalette, .shelf, .appSweep: []
        }
    }

    /// The needs of `enabled`, each once, in `PermissionNeed` order.
    static func plan(for enabled: Set<ModuleID>) -> [PermissionNeed] {
        let needed = Set(enabled.flatMap(needs(of:)))
        return PermissionNeed.allCases.filter(needed.contains)
    }

    /// The enabled tools that need `need`, in `ModuleID` order: "Used by Screenshots, OCR".
    static func tools(needing need: PermissionNeed, among enabled: Set<ModuleID>) -> [ModuleID] {
        ModuleID.allCases.filter { enabled.contains($0) && needs(of: $0).contains(need) }
    }
}
