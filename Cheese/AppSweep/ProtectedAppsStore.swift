import Foundation

/// The apps Auto-Kill leaves open: the shield toggles in its panel and Settings, kept in
/// UserDefaults by bundle ID so a renamed or updated app stays protected.
struct ProtectedAppsStore {
    static let key = "autoKillProtectedApps"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var bundleIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isProtected(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    func setProtected(_ isProtected: Bool, _ bundleID: String) {
        var ids = bundleIDs
        if isProtected {
            ids.insert(bundleID)
        } else {
            ids.remove(bundleID)
        }
        // Sorted, so the stored value doesn't churn between writes of the same set.
        defaults.set(ids.sorted(), forKey: Self.key)
    }

    func toggle(_ bundleID: String) {
        setProtected(!isProtected(bundleID), bundleID)
    }
}
