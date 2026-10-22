import AppKit
import SwiftUI

/// The values Cheese's windows and panels already share, in one place. Extracted from the existing
/// screens (see docs/DESIGN.md), not invented: every v3 view and every migrated screen uses these.
enum DesignTokens {
    /// The spacing scale, in points.
    enum Spacing {
        static let hairline: CGFloat = 2
        static let xxSmall: CGFloat = 4
        static let xSmall: CGFloat = 6
        static let small: CGFloat = 8
        static let medium: CGFloat = 10
        static let large: CGFloat = 12
        static let xLarge: CGFloat = 16
        static let xxLarge: CGFloat = 20
        static let xxxLarge: CGFloat = 24
    }

    enum Radius {
        /// Keycaps, swatch highlights, tiny thumbnails.
        static let small: CGFloat = 6
        /// List rows, page thumbnails, toolbar buttons.
        static let medium: CGFloat = 8
        /// Cards, HUDs, the draw rail, the QR code's quiet zone.
        static let large: CGFloat = 12
        /// Floating panels: the palette, the QR panel, the shelf, the share panel.
        static let panel: CGFloat = 16
    }

    enum Typography {
        static let panelTitle = Font.title3.weight(.semibold)
        static let pageTitle = Font.title.bold()
        static let heading = Font.headline
        static let body = Font.body
        static let secondary = Font.callout
        static let caption = Font.caption
        static let keycap = Font.system(.callout, design: .rounded)
        static let numeric = Font.callout.monospacedDigit()
        /// Licenses, fingerprints and other machine text.
        static let code = Font.system(.caption, design: .monospaced)
    }

    enum Size {
        /// A toolbar or rail button's hit area.
        static let iconButton = CGSize(width: 28, height: 26)
        static let rowIcon: CGFloat = 22
        static let emptyStateSymbol: CGFloat = 40
        /// A row that shows a thumbnail, like clipboard history: fixed so keyboard scrolling stays even.
        static let thumbnailRow: CGFloat = 44
        static let rowThumbnail: CGFloat = 28
        /// The accent bar on the leading edge of a tinted selected row.
        static let selectionBar: CGFloat = 2
        /// A round control floating over content, like the clipboard preview's edit badge.
        static let floatingButton: CGFloat = 28
    }

    enum Opacity {
        /// The accent tint behind an active tool or selected thumbnail.
        static let activeTint = 0.25
        /// A selected row that keeps its text colors, paired with the leading selection bar.
        static let selectedRowTint = 0.18
        static let hoverTint = 0.12
    }

    /// Animation lengths, in seconds. With Reduce Motion on, `duration(_:)` gives 0.
    enum Duration {
        static let quick: TimeInterval = 0.12
        static let standard: TimeInterval = 0.15
        static let gentle: TimeInterval = 0.25
    }

    @MainActor
    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @MainActor
    static var reducesTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// For overlays drawn with AppKit and Core Animation (capture overlay, radial menu), which can't
    /// use SwiftUI materials.
    enum Overlay {
        /// Dark badges over screen content, like the selection size: opaque with Reduce Transparency.
        @MainActor
        static var badgeBackground: NSColor {
            NSColor.black.withAlphaComponent(reducesTransparency ? 1 : 0.7)
        }

        @MainActor static var badgeFont: NSFont {
            .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        }

        @MainActor static var labelFont: NSFont {
            .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        }
    }

    /// `seconds`, or 0 when the user asked for reduced motion.
    @MainActor
    static func duration(_ seconds: TimeInterval) -> TimeInterval {
        reducesMotion ? 0 : seconds
    }

    /// A SwiftUI animation of `seconds`, or none with Reduce Motion on.
    static func animation(_ seconds: TimeInterval, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: seconds)
    }
}

/// The material behind every floating surface, or a solid window color with Reduce Transparency on.
struct CheeseSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// A small control floating over content: thin material with a hairline edge, or solid with
/// Reduce Transparency on.
struct CheeseFloatingControlSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

extension View {
    /// A floating panel's background: material, rounded to the panel radius.
    func cheesePanelBackground() -> some View {
        modifier(CheeseSurface(shape: RoundedRectangle(cornerRadius: DesignTokens.Radius.panel)))
    }

    /// A surface's background in any shape, like the toast's capsule.
    func cheeseSurface(in shape: some Shape) -> some View {
        modifier(CheeseSurface(shape: shape))
    }

    /// The background of a control floating over content, like the clipboard edit badge.
    func cheeseFloatingControl(in shape: some InsettableShape) -> some View {
        modifier(CheeseFloatingControlSurface(shape: shape))
    }
}
