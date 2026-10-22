import CryptoKit
import Foundation
import IOKit.ps
import Network
import Security
import os

/// Cheese Share's TLS identity: a self-signed certificate and its key, kept in the Keychain.
/// The certificate's SHA-256 is this Mac's LocalSend fingerprint.
struct ShareIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let fingerprint: String

    var secIdentity: sec_identity_t? {
        sec_identity_create(identity)
    }
}

/// Who this Mac is to LocalSend devices.
///
/// Cheese runs LocalSend's HTTPS mode with a self-signed certificate made on first use and kept in
/// the Keychain (see docs/LOCALSEND.md). If the Keychain refuses, it falls back to HTTP mode with a
/// random fingerprint, and Settings → Share says the connection is unencrypted. When sending to a
/// device in HTTPS mode, the device's identity is the SHA-256 of its certificate, checked against
/// what it announced.
enum TLSIdentity {
    static let fingerprintKey = "shareFingerprint"
    static let keychainLabel = "Cheese Share"

    /// The certificate: P-256, self-signed, valid for ten years.
    static func makeCertificate(key: P256.Signing.PrivateKey, now: Date = .now) throws -> Data {
        try SelfSignedCertificate.make(key: key, now: now)
    }

    /// The Keychain identity, made on first use. Nil when the Keychain won't store or find it.
    static func loadOrCreate(label: String = keychainLabel) -> ShareIdentity? {
        if let existing = existing(label: label) {
            return existing
        }
        do {
            let key = P256.Signing.PrivateKey()
            let der = try makeCertificate(key: key)
            var error: Unmanaged<CFError>?
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits: 256,
            ]
            guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, &error),
                  let certificate = SecCertificateCreateWithData(nil, der as CFData)
            else {
                Logger.share.error("Couldn't make the Share certificate: \(String(describing: error?.takeRetainedValue()), privacy: .public)")
                return nil
            }
            let keyStatus = SecItemAdd([kSecClass: kSecClassKey, kSecValueRef: secKey, kSecAttrLabel: label] as CFDictionary, nil)
            let certificateStatus = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: certificate, kSecAttrLabel: label] as CFDictionary, nil)
            guard [errSecSuccess, errSecDuplicateItem].contains(keyStatus), [errSecSuccess, errSecDuplicateItem].contains(certificateStatus) else {
                Logger.share.error("Couldn't store the Share certificate (\(keyStatus), \(certificateStatus))")
                return nil
            }
            var identity: SecIdentity?
            guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess, let identity else { return nil }
            Logger.share.info("Made Cheese Share's TLS certificate")
            return ShareIdentity(identity: identity, fingerprint: fingerprint(ofCertificate: der))
        } catch {
            Logger.share.error("Couldn't make the Share certificate: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The identity in the Keychain, without making one.
    static func existing(label: String = keychainLabel) -> ShareIdentity? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item,
              CFGetTypeID(item) == SecIdentityGetTypeID()
        else { return nil }
        let identity = unsafeDowncast(item, to: SecIdentity.self)
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        return ShareIdentity(identity: identity, fingerprint: fingerprint(ofCertificate: SecCertificateCopyData(certificate) as Data))
    }

    /// Deletes the certificate and key stored under `label`.
    static func remove(label: String) {
        for itemClass in [kSecClassCertificate, kSecClassKey] {
            SecItemDelete([kSecClass: itemClass, kSecAttrLabel: label] as CFDictionary)
        }
    }

    /// The HTTP-mode fingerprint: a random string made once and kept, used only when there's no certificate.
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
