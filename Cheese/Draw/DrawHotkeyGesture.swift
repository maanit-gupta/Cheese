import Foundation

/// Tap or hold of the draw-mode hotkey. A tap toggles draw mode. Holding it is quick ink: draw
/// while it's held, and on release the strokes stay and the overlay goes back to pass-through. Pure.
struct DrawHotkeyGesture: Equatable, Sendable {
    /// Presses shorter than this are taps.
    static let holdThreshold: TimeInterval = 0.25

    enum PressAction: Equatable, Sendable {
        /// Draw mode was off: turn it on, ready to draw.
        case enter
        /// Draw mode was in pass-through: take the mouse back so the hold can ink.
        case resumeDrawing
        case none
    }

    enum ReleaseAction: Equatable, Sendable {
        /// A tap that turned draw mode on: leave it on.
        case stay
        /// A tap while draw mode was already on: turn it off.
        case exit
        /// The end of a hold: keep the ink, give the mouse back.
        case passThrough
        case none
    }

    private var pressedAt: TimeInterval?
    private var wasActive = false

    var isHeld: Bool { pressedAt != nil }

    mutating func press(at time: TimeInterval, isActive: Bool, isPassThrough: Bool) -> PressAction {
        // Ignore key repeat.
        guard pressedAt == nil else { return .none }
        pressedAt = time
        wasActive = isActive
        if !isActive {
            return .enter
        }
        return isPassThrough ? .resumeDrawing : .none
    }

    mutating func release(at time: TimeInterval) -> ReleaseAction {
        guard let pressedAt else { return .none }
        self.pressedAt = nil
        if time - pressedAt >= Self.holdThreshold {
            return .passThrough
        }
        return wasActive ? .exit : .stay
    }

    /// Forgets a press, when draw mode is turned off some other way while the key is down.
    mutating func cancel() {
        pressedAt = nil
    }
}
