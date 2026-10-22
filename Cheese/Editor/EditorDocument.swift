import CoreGraphics

/// A color stored as plain components so documents stay `Sendable` and comparable.
struct RGBAColor: Equatable, Hashable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat = 1

    static let red = RGBAColor(red: 0.96, green: 0.23, blue: 0.21)
    static let orange = RGBAColor(red: 1, green: 0.58, blue: 0)
    static let yellow = RGBAColor(red: 1, green: 0.84, blue: 0.04)
    static let green = RGBAColor(red: 0.2, green: 0.78, blue: 0.35)
    static let blue = RGBAColor(red: 0, green: 0.48, blue: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let white = RGBAColor(red: 1, green: 1, blue: 1)

    static let presets: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .black, .white]

    func withAlpha(_ alpha: CGFloat) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// One mark on the image. Geometry is in image pixels with the origin at the top-left.
enum Annotation: Equatable, Sendable {
    case arrow(from: CGPoint, to: CGPoint, color: RGBAColor, lineWidth: CGFloat)
    case rectangle(CGRect, color: RGBAColor, lineWidth: CGFloat)
    case text(String, at: CGPoint, color: RGBAColor, fontSize: CGFloat)
    case highlight(points: [CGPoint], color: RGBAColor, lineWidth: CGFloat)
    case pixelate(CGRect, blockSize: CGFloat)
}

/// Everything the user has done to an image, applied on top of the untouched original.
struct EditorDocument: Equatable, Sendable {
    var annotations: [Annotation] = []
    /// Image pixels, top-left origin. Nil keeps the whole image.
    var crop: CGRect?
}

/// Undo and redo as whole-document snapshots; documents are small, so this stays simple.
struct EditHistory: Equatable, Sendable {
    private(set) var current: EditorDocument
    private var undoStack: [EditorDocument] = []
    private var redoStack: [EditorDocument] = []

    init(_ document: EditorDocument = EditorDocument()) {
        current = document
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Applies a change as one undoable step. Changes that leave the document as it was aren't recorded.
    mutating func apply(_ change: (inout EditorDocument) -> Void) {
        var next = current
        change(&next)
        guard next != current else { return }
        undoStack.append(current)
        redoStack.removeAll()
        current = next
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        current = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        current = next
    }
}

/// Maps between the editor's view (points, top-left origin) and image pixels for an aspect-fitted image.
enum CanvasGeometry {
    /// Where an image of `pointSize` sits when fitted into `container`: centered, aspect preserved,
    /// and never drawn larger than its natural size.
    static func fittedRect(imagePointSize: CGSize, in container: CGSize) -> CGRect {
        guard imagePointSize.width > 0, imagePointSize.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = min(container.width / imagePointSize.width, container.height / imagePointSize.height, 1)
        let size = CGSize(width: imagePointSize.width * scale, height: imagePointSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func imagePoint(fromView point: CGPoint, fitted: CGRect, imagePixelSize: CGSize) -> CGPoint {
        guard fitted.width > 0, fitted.height > 0 else { return .zero }
        return CGPoint(
            x: (point.x - fitted.minX) * imagePixelSize.width / fitted.width,
            y: (point.y - fitted.minY) * imagePixelSize.height / fitted.height
        )
    }

    /// The transform that draws image-pixel geometry into the view.
    static func imageToView(fitted: CGRect, imagePixelSize: CGSize) -> CGAffineTransform {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return .identity }
        return CGAffineTransform(translationX: fitted.minX, y: fitted.minY)
            .scaledBy(x: fitted.width / imagePixelSize.width, y: fitted.height / imagePixelSize.height)
    }

    /// A rect between two drag points, clamped to the image.
    static func rect(from start: CGPoint, to end: CGPoint, imagePixelSize: CGSize) -> CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        ).intersection(CGRect(origin: .zero, size: imagePixelSize))
    }
}
