import Foundation

/// How long Sweep keeps the keyboard and trackpad locked. Settings → Sweep offers these.
enum SweepDuration: Int, CaseIterable, Identifiable, Sendable {
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case oneMinute = 60
    case ninetySeconds = 90
    case twoMinutes = 120

    static let standard = SweepDuration.thirtySeconds

    var id: Self { self }

    var seconds: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .fifteenSeconds: "15 seconds"
        case .thirtySeconds: "30 seconds"
        case .oneMinute: "1 minute"
        case .ninetySeconds: "90 seconds"
        case .twoMinutes: "2 minutes"
        }
    }

    /// The stored number of seconds as a duration; anything Settings doesn't offer is the default.
    static func stored(_ seconds: Int?) -> SweepDuration {
        seconds.flatMap(SweepDuration.init(rawValue:)) ?? .standard
    }
}

/// One Sweep: a short countdown so the user can let go, then the lock for its duration. Pure:
/// where it is depends only on the time asked about.
struct SweepSession: Equatable, Sendable {
    /// "Locking in 3… 2… 1", long enough to take the hands off the trackpad.
    static let countdownSeconds = 3

    let startedAt: Date
    let duration: TimeInterval

    var lockStartsAt: Date { startedAt.addingTimeInterval(TimeInterval(Self.countdownSeconds)) }
    var endsAt: Date { lockStartsAt.addingTimeInterval(duration) }

    enum State: Equatable, Sendable {
        case countingDown(secondsLeft: Int)
        case locked(secondsLeft: Int)
        case finished
    }

    func state(at now: Date) -> State {
        if now < lockStartsAt {
            return .countingDown(secondsLeft: Self.wholeSeconds(lockStartsAt.timeIntervalSince(now)))
        }
        if now < endsAt {
            return .locked(secondsLeft: Self.wholeSeconds(endsAt.timeIntervalSince(now)))
        }
        return .finished
    }

    /// Rounded up, so a countdown shows 3, 2, 1 and never 0 while it still runs.
    private static func wholeSeconds(_ interval: TimeInterval) -> Int {
        max(Int(interval.rounded(.up)), 1)
    }
}

/// Holding Esc for three seconds ends a Sweep early. A brushed key is let go well before that,
/// and key repeat doesn't restart the count.
struct SweepEscHold: Equatable, Sendable {
    static let holdDuration: TimeInterval = 3

    private(set) var downSince: Date?

    var isHolding: Bool { downSince != nil }

    /// Esc went down, or repeated while held.
    mutating func keyDown(at date: Date) {
        if downSince == nil {
            downSince = date
        }
    }

    mutating func keyUp() {
        downSince = nil
    }

    func isComplete(at now: Date) -> Bool {
        guard let downSince else { return false }
        return now.timeIntervalSince(downSince) >= Self.holdDuration
    }
}

/// What the Sweep HUD says.
struct SweepHUDContent: Equatable, Sendable {
    var title: String
    var detail: String
    var symbol: String

    static func countdown(_ secondsLeft: Int) -> Self {
        Self(
            title: "Locking keyboard and trackpad in \(secondsLeft)…",
            detail: "Let go of the trackpad.",
            symbol: "hand.raised"
        )
    }

    static func locked(_ secondsLeft: Int, holdingEsc: Bool) -> Self {
        Self(
            title: "Sweep · \(clock(secondsLeft))",
            detail: holdingEsc
                ? "Keep holding Esc to stop…"
                : "Keyboard and trackpad locked · Hold Esc for 3 seconds to stop",
            symbol: "bubbles.and.sparkles"
        )
    }

    /// "0:24", "2:00".
    static func clock(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        return "\(seconds / 60):" + (seconds % 60 < 10 ? "0" : "") + "\(seconds % 60)"
    }
}
