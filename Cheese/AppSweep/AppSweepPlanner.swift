import Foundation

/// A running app as Auto-Kill sees it.
struct RunningAppInfo: Equatable, Hashable, Identifiable, Sendable {
    var pid: pid_t
    var bundleID: String?
    var name: String
    /// An ordinary app with a Dock icon (`activationPolicy == .regular`), not a helper or agent.
    var isRegular: Bool
    /// The app the user is working in.
    var isActive: Bool

    var id: pid_t { pid }
}

/// Everything, or everything but the app the user is in.
enum SweepScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case keepFrontmost

    var id: Self { self }
}

/// Which apps a sweep quits, and which it leaves because the user protected them.
struct SweepPlan: Equatable, Sendable {
    var targets: [RunningAppInfo]
    /// Apps the sweep would have quit but for the user's shield.
    var protected: [RunningAppInfo]
}

/// Decides what Auto-Kill quits. Pure: the running apps come in as plain values.
///
/// Never quit, whatever the user picks: Cheese itself, Finder, and anything that isn't a regular
/// app (background helpers, menu bar agents, the system's own processes).
enum AppSweepPlanner {
    static let finderBundleID = "com.apple.finder"

    /// - Parameters:
    ///   - ownBundleID: Cheese's bundle ID; `ownPID` catches Cheese even without one (tests, odd builds).
    static func plan(
        apps: [RunningAppInfo],
        protectedBundleIDs: Set<String>,
        scope: SweepScope,
        ownBundleID: String?,
        ownPID: pid_t
    ) -> SweepPlan {
        var plan = SweepPlan(targets: [], protected: [])
        for app in apps {
            guard app.isRegular, app.pid != ownPID else { continue }
            if let bundleID = app.bundleID, bundleID == ownBundleID || bundleID == finderBundleID { continue }
            if scope == .keepFrontmost, app.isActive { continue }
            if let bundleID = app.bundleID, protectedBundleIDs.contains(bundleID) {
                plan.protected.append(app)
            } else {
                plan.targets.append(app)
            }
        }
        return plan
    }

    /// Whether the panel lists an app at all: every regular app except Cheese.
    static func isListed(_ app: RunningAppInfo, ownBundleID: String?, ownPID: pid_t) -> Bool {
        app.isRegular && app.pid != ownPID && (app.bundleID == nil || app.bundleID != ownBundleID)
    }

    /// Finder and the like: shown, but never quit and never needing a shield.
    static func isAlwaysKept(_ app: RunningAppInfo) -> Bool {
        app.bundleID == finderBundleID
    }

    /// "Swept 8 apps · 2 protected", for the toast after a sweep.
    static func summary(swept: Int, protected: Int) -> String {
        let apps = swept == 1 ? "1 app" : "\(swept) apps"
        return protected > 0 ? "Swept \(apps) · \(protected) protected" : "Swept \(apps)"
    }

    /// "Kill All (9 Apps)" or, with Option held, "Force Kill All (9 Apps)".
    static func buttonTitle(count: Int, force: Bool) -> String {
        let apps = count == 1 ? "1 App" : "\(count) Apps"
        return "\(force ? "Force Kill All" : "Kill All") (\(apps))"
    }
}
