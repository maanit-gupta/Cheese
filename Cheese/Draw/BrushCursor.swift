import AppKit

/// Cursors that show the brush itself: a dot the size and color of the ink, so the arrow never
/// sits on top of what's being drawn.
@MainActor
enum BrushCursor {
    enum Kind: Hashable {
        case pen
        case highlighter
        case eraser
    }

    private struct Key: Hashable {
        var kind: Kind
        var diameter: Int
        var color: CanvasColor
    }

    private static var cache: [Key: NSCursor] = [:]
    /// macOS draws cursors up to about this size.
    private static let maximumDiameter: CGFloat = 120

    static func cursor(_ kind: Kind, diameter: CGFloat, color: CanvasColor) -> NSCursor {
        let size = Int(min(max(diameter, 4), maximumDiameter).rounded())
        let key = Key(kind: kind, diameter: size, color: color)
        if let cached = cache[key] {
            return cached
        }
        if cache.count > 64 {
            cache.removeAll()
        }
        let cursor = make(key)
        cache[key] = cursor
        return cursor
    }

    private static func make(_ key: Key) -> NSCursor {
        let diameter = CGFloat(key.diameter)
        // Room for the outline so it isn't clipped.
        let side = diameter + 4
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: diameter, height: diameter))
            switch key.kind {
            case .pen:
                CanvasRenderer.nsColor(key.color).setFill()
                circle.fill()
            case .highlighter:
                CanvasRenderer.nsColor(key.color.withAlpha(CanvasItem.highlighterAlpha)).setFill()
                circle.fill()
            case .eraser:
                NSColor.white.withAlphaComponent(0.35).setFill()
                circle.fill()
            }
            // Two rings, dark and light, so the brush shows on any background.
            NSColor.black.withAlphaComponent(0.55).setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let inner = NSBezierPath(ovalIn: CGRect(x: 2.75, y: 2.75, width: diameter - 1.5, height: diameter - 1.5))
            inner.lineWidth = 0.75
            inner.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}
