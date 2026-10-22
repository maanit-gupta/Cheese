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
    static func loadOrCreate(label: String = keychainLabel, defaults: UserDefaults = .standard) -> ShareIdentity? {
        if let existing = existing(label: label, defaults: defaults) {
            return existing
        }
        // The Keychain makes the key itself, in the login keychain: importing a key made elsewhere
        // needs keychain entitlements a free signing team can't get.
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrLabel: label] as [CFString: Any],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let x963 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else {
            Logger.share.error("Couldn't make the Share key: \(String(describing: error?.takeRetainedValue()), privacy: .public)")
            return nil
        }
        do {
            let der = try SelfSignedCertificate.make(publicKeyX963: x963) { data in
                var signError: Unmanaged<CFError>?
                guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, data as CFData, &signError) as Data? else {
                    throw signError?.takeRetainedValue() ?? CocoaError(.featureUnsupported)
                }
                return signature
            }
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
            let status = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: certificate, kSecAttrLabel: label] as CFDictionary, nil)
            guard status == errSecSuccess else {
                Logger.share.error("Couldn't store the Share certificate (\(status))")
                SecItemDelete([kSecValueRef: key] as CFDictionary)
                return nil
            }
            let fingerprint = fingerprint(ofCertificate: der)
            defaults.set(fingerprint, forKey: fingerprintDefaultsKey(label))
            guard let identity = identity(for: certificate, fingerprint: fingerprint) else { return nil }
            Logger.share.info("Made Cheese Share's TLS certificate")
            return identity
        } catch {
            Logger.share.error("Couldn't make the Share certificate: \(error.localizedDescription, privacy: .public)")
            SecItemDelete([kSecValueRef: key] as CFDictionary)
            return nil
        }
    }

    /// Where the fingerprint of the certificate Cheese made is remembered. Cheese finds its
    /// certificate by this fingerprint, never by label: Keychain identity searches can ignore labels
    /// and hand back another identity, like the user's code-signing certificate.
    static func fingerprintDefaultsKey(_ label: String) -> String {
        label == keychainLabel ? "shareCertificateFingerprint" : "shareCertificateFingerprint_\(label)"
    }

    /// Cheese's identity in the Keychain, without making one: the certificate whose SHA-256 is the
    /// one Cheese recorded when it made it, paired with its private key.
    static func existing(label: String = keychainLabel, defaults: UserDefaults = .standard) -> ShareIdentity? {
        guard let wanted = defaults.string(forKey: fingerprintDefaultsKey(label)),
              let certificate = certificate(withFingerprint: wanted)
        else { return nil }
        return identity(for: certificate, fingerprint: wanted)
    }

    private static func certificate(withFingerprint wanted: String) -> SecCertificate? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let items, CFGetTypeID(items) == CFArrayGetTypeID() else { return nil }
        let array = unsafeDowncast(items, to: CFArray.self) as [AnyObject]
        for item in array where CFGetTypeID(item) == SecCertificateGetTypeID() {
            let certificate = unsafeDowncast(item, to: SecCertificate.self)
            if fingerprint(ofCertificate: SecCertificateCopyData(certificate) as Data) == wanted {
                return certificate
            }
        }
        return nil
    }

    /// The certificate paired with its private key, checked to really be that certificate.
    private static func identity(for certificate: SecCertificate, fingerprint wanted: String) -> ShareIdentity? {
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess, let identity else { return nil }
        var paired: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &paired) == errSecSuccess, let paired,
              fingerprint(ofCertificate: SecCertificateCopyData(paired) as Data) == wanted
        else { return nil }
        return ShareIdentity(identity: identity, fingerprint: wanted)
    }

    /// Deletes the certificate and key made under `label`.
    static func remove(label: String, defaults: UserDefaults = .standard) {
        guard let identity = existing(label: label, defaults: defaults) else { return }
        var certificate: SecCertificate?
        var key: SecKey?
        SecIdentityCopyCertificate(identity.identity, &certificate)
        SecIdentityCopyPrivateKey(identity.identity, &key)
        for item in [certificate as AnyObject?, key as AnyObject?].compactMap(\.self) {
            SecItemDelete([kSecValueRef: item] as CFDictionary)
        }
        defaults.removeObject(forKey: fingerprintDefaultsKey(label))
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
