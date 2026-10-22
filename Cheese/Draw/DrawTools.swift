import CoreGraphics
import Foundation

enum DrawTool: String, CaseIterable, Sendable {
    case select
    case passThrough
    case pen
    case highlighter
    case eraser
    case rectangle
    case ellipse
    case line
    case arrow
    case text
    case sticky
    case laser
    case spotlight
    case zoom

    /// The single-letter key that picks the tool while drawing.
    var key: Character {
        switch self {
        case .select: "V"
        case .passThrough: "M"
        case .pen: "P"
        case .highlighter: "H"
        case .eraser: "E"
        case .rectangle: "R"
        case .ellipse: "O"
        case .line: "I"
        case .arrow: "A"
        case .text: "T"
        case .sticky: "N"
        case .laser: "L"
        case .spotlight: "S"
        case .zoom: "Z"
        }
    }

    var title: String {
        switch self {
        case .select: "Select"
        case .passThrough: "Pass-Through"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .text: "Text"
        case .sticky: "Sticky Note"
        case .laser: "Laser Pointer"
        case .spotlight: "Spotlight"
        case .zoom: "Zoom"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .passThrough: "cursorarrow.rays"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .sticky: "note.text"
        case .laser: "smallcircle.filled.circle"
        case .spotlight: "flashlight.on.fill"
        case .zoom: "plus.magnifyingglass"
        }
    }

    /// Tools with a flyout of options (color, width, fill, font size, sticky color).
    var hasOptions: Bool {
        switch self {
        case .pen, .highlighter, .rectangle, .ellipse, .line, .arrow, .text, .sticky: true
        default: false
        }
    }

    var usesWidth: Bool {
        switch self {
        case .pen, .highlighter, .rectangle, .ellipse, .line, .arrow: true
        default: false
        }
    }

    /// Laser, spotlight and zoom draw transient layers, never items.
    var isPresenter: Bool {
        self == .laser || self == .spotlight || self == .zoom
    }

    static func forKey(_ character: Character) -> DrawTool? {
        let upper = Character(character.uppercased())
        return allCases.first { $0.key == upper }
    }
}

enum BoardMode: Sendable {
    case off
    case whiteboard
    case blackboard

    var next: BoardMode {
        switch self {
        case .off: .whiteboard
        case .whiteboard: .blackboard
        case .blackboard: .off
        }
    }

    var title: String {
        switch self {
        case .off: "Board: Off"
        case .whiteboard: "Board: Whiteboard"
        case .blackboard: "Board: Blackboard"
        }
    }
}

/// The current tool and its options, shared by the toolbar and the canvases.
@MainActor
@Observable
final class DrawSettings {
    static let widthPresets: [CGFloat] = [2, 5, 10]
    static let widthRange: ClosedRange<CGFloat> = 1...40
    static let fontSizeRange: ClosedRange<CGFloat> = 12...96
    static let spotlightRadiusRange: ClosedRange<CGFloat> = 50...600
    static let zoomRange: ClosedRange<CGFloat> = 1.25...8

    var tool = DrawTool.pen
    var color = CanvasColor.presets[0]
    var width: CGFloat = 5
    var isFilled = false
    var fontSize: CGFloat = 28
    var stickyColor = CanvasColor.stickyColors[0]
    var board = BoardMode.off
    var isFlyoutOpen = false
    var canUndo = false
    var canRedo = false
    var spotlightRadius: CGFloat = 160
    var zoomFactor: CGFloat = 2

    var showsFlyout: Bool { isFlyoutOpen && tool.hasOptions }

    var style: CanvasStyle {
        CanvasStyle(color: color, width: width, isFilled: isFilled, fontSize: fontSize)
    }

    /// `[` and `]`: about 25% thinner or thicker, within range.
    func adjustWidth(thicker: Bool) {
        let next = thicker ? max(width + 1, (width * 1.25).rounded()) : min(width - 1, (width / 1.25).rounded())
        width = min(max(next, Self.widthRange.lowerBound), Self.widthRange.upperBound)
    }
}
