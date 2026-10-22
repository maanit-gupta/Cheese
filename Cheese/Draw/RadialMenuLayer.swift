import AppKit
import QuartzCore

/// Draws the right-click radial menu: eight tool slices around a brush preview, and a ring of
/// colors outside them. Geometry comes from `RadialMenuGeometry`; coordinates are the canvas's (y down).
@MainActor
final class RadialMenuLayer {
    let container = CALayer()
    let geometry = RadialMenuGeometry()
    private let disc = CAShapeLayer()
    private var slices: [CAShapeLayer] = []
    private var icons: [SymbolLayer] = []
    private var swatches: [CAShapeLayer] = []
    private let brush = CAShapeLayer()
    private let label = CATextLayer()
    private(set) var isShown = false

    init() {
        container.isHidden = true
        container.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        let size = geometry.ringRadius * 2
        container.bounds = CGRect(x: -geometry.ringRadius, y: -geometry.ringRadius, width: size, height: size)

        disc.path = CGPath(ellipseIn: CGRect(x: -geometry.sliceRadius, y: -geometry.sliceRadius, width: geometry.sliceRadius * 2, height: geometry.sliceRadius * 2), transform: nil)
        disc.fillColor = NSColor(white: 0.1, alpha: DesignTokens.reducesTransparency ? 1 : 0.82).cgColor
        disc.shadowColor = NSColor.black.cgColor
        disc.shadowOpacity = 0.35
        disc.shadowRadius = 12
        disc.shadowOffset = .zero
        container.addSublayer(disc)

        for index in 0..<RadialMenuGeometry.sliceCount {
            let slice = CAShapeLayer()
            slice.path = Self.sector(index: index, inner: geometry.cancelRadius + 2, outer: geometry.sliceRadius - 2)
            slice.fillColor = NSColor.clear.cgColor
            slice.actions = ["fillColor": NSNull()]
            container.addSublayer(slice)
            slices.append(slice)

            let icon = SymbolLayer()
            let center = geometry.center(ofSlice: index)
            icon.frame = CGRect(x: center.dx - 13, y: center.dy - 13, width: 26, height: 26)
            if let slice = RadialSlice(rawValue: index) {
                icon.symbol = Self.symbolImage(slice.tool.symbol)
            }
            container.addSublayer(icon)
            icons.append(icon)

            let swatch = CAShapeLayer()
            let swatchCenter = geometry.center(ofSwatch: index)
            swatch.path = CGPath(ellipseIn: CGRect(x: swatchCenter.dx - 11, y: swatchCenter.dy - 11, width: 22, height: 22), transform: nil)
            swatch.fillColor = CanvasRenderer.nsColor(CanvasColor.presets[index]).cgColor
            swatch.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
            swatch.lineWidth = 1.5
            swatch.shadowColor = NSColor.black.cgColor
            swatch.shadowOpacity = 0.4
            swatch.shadowRadius = 3
            swatch.shadowOffset = .zero
            swatch.actions = ["lineWidth": NSNull(), "transform": NSNull()]
            container.addSublayer(swatch)
            swatches.append(swatch)
        }

        let cancel = CAShapeLayer()
        cancel.path = CGPath(ellipseIn: CGRect(x: -geometry.cancelRadius, y: -geometry.cancelRadius, width: geometry.cancelRadius * 2, height: geometry.cancelRadius * 2), transform: nil)
        cancel.fillColor = NSColor(white: 1, alpha: 0.08).cgColor
        container.addSublayer(cancel)
        brush.actions = ["path": NSNull(), "fillColor": NSNull()]
        container.addSublayer(brush)

        label.fontSize = DesignTokens.Overlay.labelFont.pointSize
        label.font = DesignTokens.Overlay.labelFont
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.contentsScale = 2
        label.frame = CGRect(x: -80, y: geometry.ringRadius + 6, width: 160, height: 18)
        label.shadowColor = NSColor.black.cgColor
        label.shadowOpacity = 0.8
        label.shadowRadius = 3
        label.shadowOffset = .zero
        label.actions = ["contents": NSNull(), "string": NSNull()]
        container.addSublayer(label)
    }

    /// Shows the menu centered at `center`, with a brush preview of the current color and width.
    func show(at center: CGPoint, color: CanvasColor, width: CGFloat, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = center
        label.contentsScale = scale
        for icon in icons where icon.contentsScale != scale {
            icon.contentsScale = scale
            icon.setNeedsDisplay()
        }
        updateBrush(color: color, width: width)
        highlight(nil)
        container.isHidden = false
        CATransaction.commit()
        isShown = true

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = DesignTokens.Duration.quick
        container.add(fade, forKey: "appear")
        if !DesignTokens.reducesMotion {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.8
            grow.toValue = 1
            grow.duration = DesignTokens.Duration.standard
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.add(grow, forKey: "grow")
        }
    }

    func hide() {
        isShown = false
        container.removeAllAnimations()
        container.isHidden = true
    }

    func updateBrush(color: CanvasColor, width: CGFloat) {
        let radius = min(max(width, 2), geometry.cancelRadius * 2 - 6) / 2
        brush.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        brush.fillColor = CanvasRenderer.nsColor(color).cgColor
        brush.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        brush.lineWidth = 1
    }

    /// Lights up what a release here would pick.
    func highlight(_ target: RadialMenuGeometry.Target?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, slice) in slices.enumerated() {
            let isOn = target == .slice(index)
            slice.fillColor = isOn ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor : NSColor.clear.cgColor
        }
        for (index, swatch) in swatches.enumerated() {
            let isOn = target == .color(index)
            swatch.lineWidth = isOn ? 3.5 : 1.5
            let center = geometry.center(ofSwatch: index)
            swatch.transform = isOn
                ? CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-center.dx, -center.dy, 0), CATransform3DMakeScale(1.3, 1.3, 1)), CATransform3DMakeTranslation(center.dx, center.dy, 0))
                : CATransform3DIdentity
        }
        label.string = switch target {
        case let .slice(index): RadialSlice(rawValue: index)?.tool.title ?? ""
        case .color: "Color"
        case .cancel, nil: ""
        }
        CATransaction.commit()
    }

    /// An annular sector for slice `index`, slice 0 centered straight up.
    private static func sector(index: Int, inner: CGFloat, outer: CGFloat) -> CGPath {
        let width = RadialMenuGeometry.sliceAngle
        let middle = CGFloat(index) * width - .pi / 2
        let start = middle - width / 2 + 0.015
        let end = middle + width / 2 - 0.015
        let path = CGMutablePath()
        path.addArc(center: .zero, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: .zero, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    private static func symbolImage(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}

/// An SF Symbol that draws itself. Drawing (rather than an image set as contents) lets Core
/// Animation hand over a context that matches the canvas's flipped layers, so it's never upside down.
private final class SymbolLayer: CALayer {
    var symbol: NSImage? {
        didSet { setNeedsDisplay() }
    }

    override func draw(in context: CGContext) {
        guard let symbol, symbol.size.width > 0, symbol.size.height > 0 else { return }
        let scale = min(bounds.width / symbol.size.width, bounds.height / symbol.size.height)
        let size = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: contentsAreFlipped())
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
