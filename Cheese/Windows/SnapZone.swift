import CoreGraphics

/// Where dropping a dragged window at a screen edge or corner puts it.
enum SnapZone: Equatable, Hashable, Sendable, CaseIterable {
    case leftHalf
    case rightHalf
    case maximize
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
}

/// The zone under the pointer during a window drag and the frame it stands for.
struct SnapZoneHit: Equatable, Sendable {
    var zone: SnapZone
    /// Target frame in Quartz coordinates, inside the display's visible frame.
    var frame: CGRect
    var displayIndex: Int
}

/// Hot-zone math for drag-to-edge snapping. Every rect and point is in Quartz global coordinates
/// (top-left origin, y down). `displays` are full display frames (the pointer reaches the menu bar
/// and the Dock), `visibleFrames` the same displays without them, in the same order.
enum SnapZoneLayout {
    /// How close to a display edge the pointer must be.
    static let edgeThickness: CGFloat = 12
    /// The square at each display corner that means a quarter.
    static let cornerSize: CGFloat = 48

    /// The zone under `point`, or nil when it's away from every edge. An edge another display
    /// continues past is no edge: crossing it moves the window to that display instead of snapping.
    static func hit(at point: CGPoint, displays: [CGRect], visibleFrames: [CGRect]) -> SnapZoneHit? {
        guard displays.count == visibleFrames.count,
              let index = DisplayGeometry.indexOfDisplay(containing: point, frames: displays)
        else { return nil }
        guard let zone = zone(at: point, display: displays[index], others: displays.indices.filter { $0 != index }.map { displays[$0] })
        else { return nil }
        return SnapZoneHit(zone: zone, frame: frame(for: zone, in: visibleFrames[index]), displayIndex: index)
    }

    /// The zone under `point` within one display.
    static func zone(at point: CGPoint, display: CGRect, others: [CGRect] = []) -> SnapZone? {
        let display = display.standardized
        // The pointer's last row and column are maxX - 1 / maxY - 1; clamp so they count as the edge.
        let x = min(max(point.x, display.minX), display.maxX - 1)
        let y = min(max(point.y, display.minY), display.maxY - 1)

        func open(_ beyond: CGPoint) -> Bool { !others.contains { $0.contains(beyond) } }
        let leftOpen = open(CGPoint(x: display.minX - 1, y: y))
        let rightOpen = open(CGPoint(x: display.maxX, y: y))
        let topOpen = open(CGPoint(x: x, y: display.minY - 1))
        let bottomOpen = open(CGPoint(x: x, y: display.maxY))

        let fromLeft = x - display.minX
        let fromRight = display.maxX - 1 - x
        let fromTop = y - display.minY
        let fromBottom = display.maxY - 1 - y

        // Corners first: a corner counts while either of its edges is open.
        let nearLeft = fromLeft < cornerSize, nearRight = fromRight < cornerSize
        let nearTop = fromTop < cornerSize, nearBottom = fromBottom < cornerSize
        let atLeft = fromLeft < edgeThickness, atRight = fromRight < edgeThickness
        let atTop = fromTop < edgeThickness, atBottom = fromBottom < edgeThickness
        if nearTop, nearLeft, (atTop && topOpen) || (atLeft && leftOpen) { return .topLeftQuarter }
        if nearTop, nearRight, (atTop && topOpen) || (atRight && rightOpen) { return .topRightQuarter }
        if nearBottom, nearLeft, (atBottom && bottomOpen) || (atLeft && leftOpen) { return .bottomLeftQuarter }
        if nearBottom, nearRight, (atBottom && bottomOpen) || (atRight && rightOpen) { return .bottomRightQuarter }

        if atLeft, leftOpen { return .leftHalf }
        if atRight, rightOpen { return .rightHalf }
        if atTop, topOpen { return .maximize }
        if atBottom, bottomOpen { return .bottomHalf }
        return nil
    }

    /// The frame for `zone` within one display's visible frame. Splits on whole points, no gaps.
    static func frame(for zone: SnapZone, in visible: CGRect) -> CGRect {
        let visible = visible.standardized
        switch zone {
        case .leftHalf: return SnapLayout.frame(for: .leftHalf, in: visible)
        case .rightHalf: return SnapLayout.frame(for: .rightHalf, in: visible)
        case .maximize: return SnapLayout.frame(for: .maximize, in: visible)
        case .bottomHalf: return SnapLayout.frame(for: .bottomHalf, in: visible)
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter:
            let leftWidth = (visible.width / 2).rounded(.down)
            let topHeight = (visible.height / 2).rounded(.down)
            let isLeft = zone == .topLeftQuarter || zone == .bottomLeftQuarter
            let isTop = zone == .topLeftQuarter || zone == .topRightQuarter
            return CGRect(
                x: isLeft ? visible.minX : visible.minX + leftWidth,
                y: isTop ? visible.minY : visible.minY + topHeight,
                width: isLeft ? leftWidth : visible.width - leftWidth,
                height: isTop ? topHeight : visible.height - topHeight
            )
        }
    }
}

/// Tells a window drag apart from any other drag (selecting text, a slider, a canvas): only a
/// gesture during which the window under the pointer actually moved counts. Pure; the monitor
/// feeds it events and AX readings.
struct WindowDragTracker: Equatable, Sendable {
    /// How far the window must move from where it was when the gesture began.
    static let moveThreshold: CGFloat = 3
    /// Seconds between samples while the button is held (~60 Hz).
    static let sampleInterval: Double = 1.0 / 60

    enum Phase: Equatable, Sendable {
        /// No button held.
        case idle
        /// Button down; nothing read yet (plain clicks never cost an AX call).
        case pressed
        /// The window under the pointer was found at this origin; waiting to see it move.
        case watching(initialOrigin: CGPoint)
        /// The window is being dragged.
        case dragging
        /// Not a window drag (no window, or the gesture was ruled out) until the button comes up.
        case ignored
    }

    private(set) var phase: Phase = .idle
    private var lastSample: Double?

    var isDraggingWindow: Bool { phase == .dragging }

    mutating func mouseDown() {
        phase = .pressed
        lastSample = nil
    }

    /// Whether a drag event at `time` (seconds) should be looked at, at most once per sample interval.
    mutating func shouldSample(at time: Double) -> Bool {
        switch phase {
        case .idle, .ignored: return false
        case .pressed, .watching, .dragging: break
        }
        if let lastSample, time - lastSample < Self.sampleInterval { return false }
        lastSample = time
        return true
    }

    /// The first sample: the window under the pointer and where it is, or nil when there's none.
    mutating func found(windowOrigin: CGPoint?) {
        guard phase == .pressed else { return }
        phase = windowOrigin.map { .watching(initialOrigin: $0) } ?? .ignored
    }

    /// A later sample of the window's origin. Returns true once the gesture is a window drag.
    @discardableResult
    mutating func moved(windowOrigin: CGPoint?) -> Bool {
        guard case .watching(let initial) = phase else { return phase == .dragging }
        guard let windowOrigin else {
            phase = .ignored
            return false
        }
        if hypot(windowOrigin.x - initial.x, windowOrigin.y - initial.y) > Self.moveThreshold {
            phase = .dragging
        }
        return phase == .dragging
    }

    /// Button up. Returns whether the gesture was a window drag.
    mutating func mouseUp() -> Bool {
        defer {
            phase = .idle
            lastSample = nil
        }
        return phase == .dragging
    }
}
