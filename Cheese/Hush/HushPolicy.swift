import Foundation

/// What's showing the screen to someone else.
enum ShareSource: Equatable, Sendable {
    /// A meeting or recording app, by name ("Zoom").
    case app(String)
    /// The display is mirrored, to a projector or an AirPlay screen.
    case mirroring
    /// Someone is viewing this Mac through Screen Sharing.
    case remote
    /// Cheese itself is recording the screen.
    case cheeseRecording

    var title: String {
        switch self {
        case let .app(name): "\(name) is sharing the screen"
        case .mirroring: "The display is mirrored"
        case .remote: "Someone is viewing this Mac with Screen Sharing"
        case .cheeseRecording: "Cheese is recording the screen"
        }
    }
}

/// A Hush the user started from the menu: for a while, until a time, or until turned off.
struct ManualHush: Equatable, Sendable {
    let duration: CaffeinateDuration
    let startedAt: Date

    var deadline: Date? { duration.deadline(from: startedAt) }

    func isOver(at now: Date) -> Bool {
        deadline.map { now >= $0 } ?? false
    }
}

/// Why notifications are hushed right now.
enum HushReason: Equatable, Sendable {
    case manual(ManualHush)
    case sharing(ShareSource)
    /// Sharing stopped a moment ago; notifications come back at `until`.
    case grace(until: Date)
}

/// Whether notifications should be hushed. Pure: depends only on what it's told and the time.
struct HushPolicy: Equatable, Sendable {
    /// How long after sharing stops notifications stay hushed, so a quick stop and restart
    /// doesn't let a banner through.
    static let grace: TimeInterval = 30

    var manual: ManualHush?
    /// "Hush Automatically While Sharing".
    var automatic = true
    /// What's sharing the screen at the last check (Cheese's own recordings count).
    var sharing: ShareSource?
    /// The last time anything was seen sharing.
    var lastSharingSeen: Date?
    /// The user turned Hush off during a share: stay off until that share is over.
    var snoozedUntilSharingEnds = false

    func reason(at now: Date) -> HushReason? {
        if let manual, !manual.isOver(at: now) {
            return .manual(manual)
        }
        guard automatic, !snoozedUntilSharingEnds else { return nil }
        if let sharing {
            return .sharing(sharing)
        }
        if let lastSharingSeen {
            let until = lastSharingSeen.addingTimeInterval(Self.grace)
            if now < until {
                return .grace(until: until)
            }
        }
        return nil
    }

    func shouldHush(at now: Date) -> Bool {
        reason(at: now) != nil
    }

    /// Records a check of what's sharing. A share that ended (and its grace with it) lifts a snooze.
    mutating func observe(_ source: ShareSource?, at now: Date) {
        sharing = source
        if source != nil {
            lastSharingSeen = now
        } else if snoozedUntilSharingEnds, !isInGrace(at: now) {
            snoozedUntilSharingEnds = false
        }
    }

    private func isInGrace(at now: Date) -> Bool {
        guard let lastSharingSeen else { return false }
        return now < lastSharingSeen.addingTimeInterval(Self.grace)
    }

    /// The user asked for notifications back: ends a manual Hush, and an automatic one until the
    /// current share is over.
    mutating func turnOff(at now: Date) {
        manual = nil
        if sharing != nil || isInGrace(at: now) {
            snoozedUntilSharingEnds = true
        }
    }

    /// The text beside the Hush icon: the time left on a timed Hush, nothing otherwise.
    func indicatorText(at now: Date) -> String? {
        guard case let .manual(manual) = reason(at: now), let deadline = manual.deadline else { return nil }
        return CaffeinateSchedule.indicatorText(remaining: deadline.timeIntervalSince(now))
    }
}
