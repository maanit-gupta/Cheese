import CryptoKit
import Foundation
import IOKit.ps

/// Who this Mac is to LocalSend devices.
///
/// Cheese runs LocalSend's HTTP mode (see docs/LOCALSEND.md): without a TLS certificate of its own,
/// its fingerprint is a random string made once and kept. When sending to a device in HTTPS mode,
/// the device's identity is the SHA-256 of its certificate, checked against what it announced.
enum TLSIdentity {
    static let fingerprintKey = "shareFingerprint"

    /// Cheese runs without encryption until it has a certificate of its own.
    static let transport = LocalSend.Transport.http

    /// This Mac's fingerprint, made on first use.
    static func fingerprint(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: fingerprintKey), !existing.isEmpty {
            return existing
        }
        let made = ShareRules.makeToken() + ShareRules.makeToken()
        defaults.set(made, forKey: fingerprintKey)
        return made
    }

    /// SHA-256 of a DER certificate as lowercase hex, LocalSend's fingerprint format.
    static func fingerprint(ofCertificate der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a device's certificate matches the fingerprint it announced.
    static func matches(_ certificateFingerprint: String?, announced: String) -> Bool {
        guard let certificateFingerprint else { return false }
        return certificateFingerprint.caseInsensitiveCompare(announced) == .orderedSame
    }

    /// "MacBook" when the Mac has an internal battery, otherwise "Mac". LocalSend's device types
    /// don't tell laptops from desktops, so the model carries it.
    static var deviceModel: String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return "Mac" }
        let hasBattery = sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
        return hasBattery ? "MacBook" : "Mac"
    }
}
