import AppKit
import CoreGraphics
import Darwin

/// Looks at the screen right now and says what, if anything, is sharing it.
@MainActor
protocol ShareDetecting: AnyObject {
    func detect() -> ShareSource?
}

/// Reads the window list for meeting and recording apps' share indicators, the displays for
/// mirroring, and the session for Screen Sharing viewers. Window titles need Screen Recording;
/// without it only mirroring and Screen Sharing are noticed.
@MainActor
final class ScreenShareDetector: ShareDetecting {
    private let signals = ShareSignals(rules: ShareSignals.bundledRules())
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var bundleIDs: [pid_t: String] = [:]

    func detect() -> ShareSource? {
        signals.source(
            windows: windows(),
            mirroring: Self.isMirroring(),
            remoteSession: Self.isRemoteSession(),
            excludingPID: ownPID
        )
    }

    private func windows() -> [WindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info -> WindowSnapshot? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let name = info[kCGWindowName as String] as? String, !name.isEmpty
            else { return nil }
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            return WindowSnapshot(
                ownerBundleID: bundleID(of: pid),
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                name: name,
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                bounds: bounds,
                pid: pid
            )
        }
    }

    /// Owner names are localized ("Control Centre"), so rules match bundle IDs.
    private func bundleID(of pid: pid_t) -> String? {
        if let known = bundleIDs[pid] { return known }
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
        bundleIDs[pid] = id
        return id
    }

    private static func isMirroring() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    /// The session reports a Screen Sharing viewer; failing that, the processes macOS runs only
    /// while someone is connected.
    private static func isRemoteSession() -> Bool {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsShared"] as? Bool == true {
            return true
        }
        return isRunning(anyOf: ["screensharingd", "ScreensharingAge"])
    }

    /// Whether a process with one of these names runs. `proc_name` cuts names to 16 characters.
    private static func isRunning(anyOf names: Set<String>) -> Bool {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return false }
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            let length = proc_name(pid, &name, UInt32(name.count))
            guard length > 0 else { continue }
            let processName = String(decoding: name.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if names.contains(processName) {
                return true
            }
        }
        return false
    }
}
