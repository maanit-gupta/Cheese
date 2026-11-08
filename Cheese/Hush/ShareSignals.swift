import CoreGraphics
import Foundation
import os

/// One on-screen window, as the window list describes it.
struct WindowSnapshot: Equatable, Sendable {
    var ownerBundleID: String?
    var ownerName: String
    var name: String
    var layer: Int
    var bounds: CGRect
    var pid: Int32
}

/// How one app shows that it's sharing or recording the screen: a window of its own whose title
/// contains one of `nameContains` (case ignored), like Zoom's share toolbar. Listed in
/// `ShareIndicators.json`, so supporting another app needs no code.
struct ShareIndicatorRule: Decodable, Equatable, Sendable {
    /// How Hush names the app ("Zoom").
    var app: String
    var bundleIDs: [String]
    var nameContains: [String]
    /// Only windows at most this tall count, for indicators that are small bars (a browser's
    /// "is sharing your screen" bar, not a tab titled that way).
    var maxHeight: Double?

    func matches(_ window: WindowSnapshot) -> Bool {
        guard let bundleID = window.ownerBundleID, bundleIDs.contains(bundleID), !window.name.isEmpty else { return false }
        if let maxHeight, window.bounds.height > maxHeight { return false }
        let name = window.name.lowercased()
        return nameContains.contains { name.contains($0.lowercased()) }
    }
}

/// Decides from the window list and display state whether the screen is being shared. Pure.
struct ShareSignals: Sendable {
    let rules: [ShareIndicatorRule]

    /// Remote viewing first, then mirroring, then the first app whose indicator is on screen.
    /// Cheese's own windows never count.
    func source(windows: [WindowSnapshot], mirroring: Bool, remoteSession: Bool, excludingPID: Int32) -> ShareSource? {
        if remoteSession { return .remote }
        if mirroring { return .mirroring }
        for window in windows where window.pid != excludingPID {
            if let rule = rules.first(where: { $0.matches(window) }) {
                return .app(rule.app)
            }
        }
        return nil
    }

    /// The rules bundled with Cheese.
    static func bundledRules(in bundle: Bundle = .main) -> [ShareIndicatorRule] {
        guard let url = bundle.url(forResource: "ShareIndicators", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            Logger.hush.error("ShareIndicators.json is missing")
            return []
        }
        do {
            return try JSONDecoder().decode([ShareIndicatorRule].self, from: data)
        } catch {
            Logger.hush.error("ShareIndicators.json doesn't parse: \(error.localizedDescription)")
            return []
        }
    }
}
