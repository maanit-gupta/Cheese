import CoreGraphics

/// How Fill to Screen sizes windows (Settings → Windows).
enum WindowFillMode: String, CaseIterable, Identifiable, Sendable {
    /// Leaves room for the Stage Manager strip whenever Stage Manager shows it; otherwise the same
    /// as `fullVisibleFrame`.
    case stageManagerSafe
    /// The whole visible frame (menu bar and Dock respected), even with Stage Manager on.
    case fullVisibleFrame

    var id: Self { self }

    var title: String {
        switch self {
        case .stageManagerSafe: "Leave room for Stage Manager"
        case .fullVisibleFrame: "Fill the whole visible screen"
        }
    }
}

enum DockOrientation: String, Sendable {
    case left
    case bottom
    case right
}

/// Which side of each display the Stage Manager strip sits on.
enum StageStripEdge: Equatable, Sendable {
    case left
    case right
}

/// What Cheese knows about Stage Manager from the system's preferences.
struct StageManagerState: Equatable, Sendable {
    var isEnabled: Bool
    /// "Show recent apps in Stage Manager" is off, so the strip only appears at the screen's edge.
    var stripAutoHides: Bool
    var dockOrientation: DockOrientation

    static let off = StageManagerState(isEnabled: false, stripAutoHides: false, dockOrientation: .bottom)
}

/// Where a fill puts windows: the visible frame less a strip on one side.
struct FillLayout: Equatable, Sendable {
    var stripInset: CGFloat
    var stripEdge: StageStripEdge

    /// The whole visible frame.
    static let fullVisibleFrame = FillLayout(stripInset: 0, stripEdge: .left)
}

/// Frame math for Fill to Screen. Windows are resized to fill a display, never put into native full
/// screen, so Stage Manager's strip of recent apps stays visible beside them.
///
/// The strip runs down a vertical edge, so only x changes: the math is the same in Quartz and AppKit
/// coordinates (see `DisplayGeometry`). Callers pass Quartz rects, like `SnapLayout`.
enum StageManagerLayout {
    static let defaultStripInset: CGFloat = 196
    static let stripInsetRange: ClosedRange<CGFloat> = 140...260

    /// The strip is on the left, or on the right when the Dock has the left edge.
    static func stripEdge(dock: DockOrientation) -> StageStripEdge {
        dock == .left ? .right : .left
    }

    /// The room to leave for the strip: none unless Stage Manager is on with its strip showing and
    /// the user wants room for it.
    static func layout(mode: WindowFillMode, stageManager: StageManagerState, configuredInset: CGFloat) -> FillLayout {
        guard mode == .stageManagerSafe, stageManager.isEnabled, !stageManager.stripAutoHides else {
            return .fullVisibleFrame
        }
        let inset = min(max(configuredInset, stripInsetRange.lowerBound), stripInsetRange.upperBound)
        return FillLayout(stripInset: inset, stripEdge: stripEdge(dock: stageManager.dockOrientation))
    }

    /// A display's visible frame less the strip. The strip never takes more than half a display.
    static func fillFrame(in visible: CGRect, layout: FillLayout) -> CGRect {
        let visible = visible.standardized
        let inset = min(max(layout.stripInset, 0), (visible.width / 2).rounded(.down))
        switch layout.stripEdge {
        case .left:
            return CGRect(x: visible.minX + inset, y: visible.minY, width: visible.width - inset, height: visible.height)
        case .right:
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width - inset, height: visible.height)
        }
    }

    /// The fill frame on the display holding most of `windowFrame`.
    static func target(for windowFrame: CGRect, displays: [CGRect], layout: FillLayout) -> SnapTarget? {
        guard let index = DisplayGeometry.indexOfDisplay(bestMatching: windowFrame, frames: displays) else { return nil }
        return SnapTarget(frame: fillFrame(in: displays[index], layout: layout), displayIndex: index)
    }

    /// "Filled 11 windows across 7 apps", for the toast.
    static func summary(windows: Int, apps: Int) -> String {
        guard windows > 0 else { return "No windows to fill" }
        let windowText = windows == 1 ? "1 window" : "\(windows) windows"
        let appText = apps == 1 ? "1 app" : "\(apps) apps"
        return "Filled \(windowText) across \(appText)"
    }
}
