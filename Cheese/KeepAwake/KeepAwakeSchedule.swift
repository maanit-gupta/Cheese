import Foundation

/// Keep-awake time math: when a picked time ends, and how the menu bar countdown reads.
enum KeepAwakeSchedule {
    /// The next moment the clock reads `hour:minute`. A time that has already passed today means tomorrow.
    static func targetDate(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date {
        let components = DateComponents(hour: hour, minute: minute, second: 0)
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(24 * 60 * 60)
    }

    /// Countdown text next to the menu bar icon: `1h 12m`, `42m`, then seconds in the final minute.
    /// Rounds up, so it never reads `0m` while time is left.
    static func indicatorText(remaining: TimeInterval) -> String {
        guard remaining > 60 else {
            return "\(max(Int(remaining.rounded(.up)), 0))s"
        }
        let minutes = Int((remaining / 60).rounded(.up))
        guard minutes >= 60 else { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// The indicator for indefinite keep awake.
    static let indefiniteText = "∞"

    /// Seconds until `indicatorText` next changes: once a minute, or once a second in the final minute.
    static func nextRefresh(remaining: TimeInterval) -> TimeInterval {
        guard remaining > 0 else { return 0 }
        let step: TimeInterval = remaining > 60 ? 60 : 1
        let intoStep = remaining.truncatingRemainder(dividingBy: step)
        return intoStep == 0 ? step : intoStep
    }
}
