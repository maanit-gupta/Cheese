import Foundation

/// A device the user chose "Always accept from this device" for.
struct TrustedDevice: Codable, Equatable, Identifiable, Sendable {
    /// Its certificate fingerprint (in LocalSend's HTTP mode, the fingerprint it reports).
    var fingerprint: String
    var alias: String
    var addedAt: Date

    var id: String { fingerprint }
}

/// Devices whose sends are accepted without asking, keyed by fingerprint. Removable in
/// Settings → Share.
struct TrustStore {
    static let defaultsKey = "shareTrustedDevices"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var devices: [TrustedDevice] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let devices = try? JSONDecoder().decode([TrustedDevice].self, from: data)
        else { return [] }
        return devices.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    func isTrusted(_ fingerprint: String) -> Bool {
        !fingerprint.isEmpty && devices.contains { $0.fingerprint.caseInsensitiveCompare(fingerprint) == .orderedSame }
    }

    /// Trusts the device, updating its name if it's already trusted. Empty fingerprints can't be trusted.
    func trust(fingerprint: String, alias: String, now: Date = .now) {
        guard !fingerprint.isEmpty else { return }
        var devices = devices.filter { $0.fingerprint.caseInsensitiveCompare(fingerprint) != .orderedSame }
        devices.append(TrustedDevice(fingerprint: fingerprint, alias: alias, addedAt: now))
        save(devices)
    }

    func remove(_ fingerprint: String) {
        save(devices.filter { $0.fingerprint.caseInsensitiveCompare(fingerprint) != .orderedSame })
    }

    private func save(_ devices: [TrustedDevice]) {
        defaults.set(try? JSONEncoder().encode(devices), forKey: Self.defaultsKey)
    }
}
