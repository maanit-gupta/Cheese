import CoreGraphics
import Foundation

/// An RGBA color, kept free of AppKit so the canvas model stays pure.
struct CanvasColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }

    func withAlpha(_ alpha: Double) -> CanvasColor {
        var copy = self
        copy.alpha = alpha
        return copy
    }

    /// The nine presets, picked with `1`–`9`.
    static let presets: [CanvasColor] = [
        CanvasColor(hex: 0xFF3B30), // red
        CanvasColor(hex: 0xFF9500), // orange
        CanvasColor(hex: 0xFFCC00), // yellow
        CanvasColor(hex: 0x34C759), // green
        CanvasColor(hex: 0x007AFF), // blue
        CanvasColor(hex: 0xAF52DE), // purple
        CanvasColor(hex: 0xFF2D55), // pink
        CanvasColor(hex: 0x1C1C1E), // black
        CanvasColor(hex: 0xFFFFFF), // white
    ]

    /// Miro's sticky note colors; yellow is the default.
    static let stickyColors: [CanvasColor] = [
        CanvasColor(hex: 0xFFF9B1), // yellow
        CanvasColor(hex: 0xF5D128), // dark yellow
        CanvasColor(hex: 0xFF9D48), // orange
        CanvasColor(hex: 0xD5F692), // light green
        CanvasColor(hex: 0xC9DF56), // green
        CanvasColor(hex: 0xA6CCF5), // light blue
        CanvasColor(hex: 0x6CD8FA), // cyan
        CanvasColor(hex: 0xFFCEE0), // pink
        CanvasColor(hex: 0xBE88C7), // violet
    ]
}

/// How an item is drawn.
struct CanvasStyle: Hashable, Sendable {
    var color: CanvasColor
    /// Stroke width in points.
    var width: CGFloat
    /// Shapes only: filled or outlined.
    var isFilled = false
    /// Text only.
    var fontSize: CGFloat = 24
}

enum ShapeKind: Hashable, Sendable {
    case rectangle
    case ellipse
}

/// One object on the canvas. Geometry is in the display's view coordinates (points, y down).
struct CanvasItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Freehand input points; drawn smoothed. Highlighter strokes render beneath everything else.
        case stroke(points: [CGPoint], isHighlighter: Bool)
        case shape(ShapeKind, rect: CGRect)
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        /// `rect` is measured from the text when it's committed.
        case text(String, rect: CGRect)
        case sticky(String, rect: CGRect, color: CanvasColor)
    }

    /// The default sticky note size, in points.
    static let stickySize = CGSize(width: 200, height: 200)
    /// Highlighters draw this many times wider than the chosen width, at this opacity.
    static let highlighterWidthFactor: CGFloat = 4
    static let highlighterAlpha = 0.35

    let id: UUID
    var kind: Kind
    var style: CanvasStyle

    init(id: UUID = UUID(), kind: Kind, style: CanvasStyle) {
        self.id = id
        self.kind = kind
        self.style = style
    }

    var isHighlighter: Bool {
        if case .stroke(_, true) = kind { return true }
        return false
    }

    /// The width the item is actually drawn at.
    var renderedWidth: CGFloat {
        isHighlighter ? style.width * Self.highlighterWidthFactor : style.width
    }

    var text: String? {
        switch kind {
        case let .text(text, _), let .sticky(text, _, _): text
        default: nil
        }
    }

    /// The bare geometry, without stroke width.
    var geometryBounds: CGRect {
        switch kind {
        case let .stroke(points, _):
            return Self.boundingBox(of: points)
        case let .shape(_, rect), let .text(_, rect), let .sticky(_, rect, _):
            return rect.standardized
        case let .line(from, to), let .arrow(from, to):
            return Self.boundingBox(of: [from, to])
        }
    }

    /// What the item covers on screen: geometry plus half the stroke. Used for selection boxes and handles.
    var bounds: CGRect {
        switch kind {
        case .text, .sticky:
            return geometryBounds
        case .shape where style.isFilled:
            return geometryBounds.insetBy(dx: -style.width / 2, dy: -style.width / 2)
        default:
            let pad = renderedWidth / 2
            return geometryBounds.insetBy(dx: -pad, dy: -pad)
        }
    }

    func translated(by offset: CGSize) -> CanvasItem {
        mapped(scaleX: 1, scaleY: 1) { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) }
    }

    /// The item stretched so that `old` maps onto `new`. Text grows its font with the height.
    func resized(from old: CGRect, to new: CGRect) -> CanvasItem {
        let scaleX = old.width > 0 ? new.width / old.width : 1
        let scaleY = old.height > 0 ? new.height / old.height : 1
        return mapped(scaleX: scaleX, scaleY: scaleY) { point in
            CGPoint(x: new.minX + (point.x - old.minX) * scaleX, y: new.minY + (point.y - old.minY) * scaleY)
        }
    }

    func withText(_ text: String, rect: CGRect? = nil) -> CanvasItem {
        var copy = self
        switch kind {
        case let .text(_, oldRect):
            copy.kind = .text(text, rect: rect ?? oldRect)
        case let .sticky(_, oldRect, color):
            copy.kind = .sticky(text, rect: rect ?? oldRect, color: color)
        default:
            break
        }
        return copy
    }

    private func mapped(scaleX: CGFloat, scaleY: CGFloat, _ transform: (CGPoint) -> CGPoint) -> CanvasItem {
        func rect(_ rect: CGRect) -> CGRect {
            let rect = rect.standardized
            return Self.boundingBox(of: [transform(rect.origin), transform(CGPoint(x: rect.maxX, y: rect.maxY))])
        }
        var copy = self
        switch kind {
        case let .stroke(points, isHighlighter):
            copy.kind = .stroke(points: points.map(transform), isHighlighter: isHighlighter)
        case let .shape(shape, oldRect):
            copy.kind = .shape(shape, rect: rect(oldRect))
        case let .line(from, to):
            copy.kind = .line(from: transform(from), to: transform(to))
        case let .arrow(from, to):
            copy.kind = .arrow(from: transform(from), to: transform(to))
        case let .text(text, oldRect):
            copy.kind = .text(text, rect: rect(oldRect))
            copy.style.fontSize = max(4, style.fontSize * abs(scaleY))
        case let .sticky(text, oldRect, color):
            copy.kind = .sticky(text, rect: rect(oldRect), color: color)
        }
        return copy
    }

    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
