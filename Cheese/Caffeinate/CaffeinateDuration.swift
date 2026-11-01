import Foundation

/// The fixed lengths the Caffeinate menu offers.
enum CaffeinatePreset: String, CaseIterable, Sendable {
    case thirtyMinutes
    case oneHour
    case twoHours

    var seconds: TimeInterval {
        switch self {
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        }
    }

    var title: String {
        switch self {
        case .thirtyMinutes: "For 30 Minutes"
        case .oneHour: "For 1 Hour"
        case .twoHours: "For 2 Hours"
        }
    }

    var phrase: String {
        switch self {
        case .thirtyMinutes: "for 30 minutes"
        case .oneHour: "for 1 hour"
        case .twoHours: "for 2 hours"
        }
    }
}

/// How long a Caffeinate session lasts.
enum CaffeinateDuration: Equatable, Sendable {
    case preset(CaffeinatePreset)
    case until(Date)
    case indefinitely

    /// When the session ends, starting at `start`; nil for indefinitely.
    func deadline(from start: Date) -> Date? {
        switch self {
        case let .preset(preset): start.addingTimeInterval(preset.seconds)
        case let .until(date): date
        case .indefinitely: nil
        }
    }

    /// How the start toast finishes "Caffeinating …".
    func phrase(locale: Locale = .current) -> String {
        switch self {
        case let .preset(preset):
            return preset.phrase
        case let .until(date):
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.locale = locale
            return "until \(date.formatted(style))"
        case .indefinitely:
            return "until you turn it off"
        }
    }
}
