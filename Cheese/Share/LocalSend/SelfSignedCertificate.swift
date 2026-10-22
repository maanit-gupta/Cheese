import CryptoKit
import Foundation

/// Just enough DER to write one certificate. Pure, so every byte is unit-tested.
enum DER {
    static func element(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    /// Short form below 128, otherwise long form.
    static func length(_ count: Int) -> [UInt8] {
        guard count >= 128 else { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func sequence(_ parts: [UInt8]...) -> [UInt8] { element(0x30, parts.flatMap(\.self)) }
    static func set(_ parts: [UInt8]...) -> [UInt8] { element(0x31, parts.flatMap(\.self)) }
    static func octetString(_ bytes: [UInt8]) -> [UInt8] { element(0x04, bytes) }
    static func utf8String(_ text: String) -> [UInt8] { element(0x0C, Array(text.utf8)) }
    static let boolTrue: [UInt8] = [0x01, 0x01, 0xFF]
    static let null: [UInt8] = [0x05, 0x00]

    /// A BIT STRING whose last byte has `unusedBits` padding bits.
    static func bitString(_ bytes: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] {
        element(0x03, [unusedBits] + bytes)
    }

    /// A non-negative INTEGER from big-endian bytes: leading zeros trimmed, a 0x00 added when the
    /// top bit is set so it doesn't read as negative.
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var trimmed = Array(bytes.drop { $0 == 0 })
        if trimmed.isEmpty { trimmed = [0] }
        if let first = trimmed.first, first & 0x80 != 0 { trimmed.insert(0, at: 0) }
        return element(0x02, trimmed)
    }

    /// An OBJECT IDENTIFIER from its dotted form, like "1.2.840.10045.2.1".
    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard arcs.count >= 2 else { return element(0x06, []) }
        var content = base128(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) {
            content += base128(arc)
        }
        return element(0x06, content)
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        var bytes = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return bytes
    }

    /// UTCTime through 2049, GeneralizedTime from 2050, as RFC 5280 requires. Always UTC, to the second.
    static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = parts.year ?? 1970
        let rest = [parts.month, parts.day, parts.hour, parts.minute, parts.second].map { String(format: "%02d", $0 ?? 0) }.joined()
        if year < 2050 {
            return element(0x17, Array((String(format: "%02d", year % 100) + rest + "Z").utf8))
        }
        return element(0x18, Array((String(format: "%04d", year) + rest + "Z").utf8))
    }
}

/// Cheese Share's certificate: self-signed ECDSA P-256 with SHA-256, for TLS server and client use.
enum SelfSignedCertificate {
    static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
    static let ecPublicKey = "1.2.840.10045.2.1"
    static let prime256v1 = "1.2.840.10045.3.1.7"

    /// The certificate's DER bytes, valid from an hour before `now` for ten years.
    static func make(
        key: P256.Signing.PrivateKey,
        commonName: String = "Cheese Share",
        organization: String = "Cheese",
        now: Date = .now,
        serial: [UInt8] = (0..<16).map { _ in UInt8.random(in: 0...255) }
    ) throws -> Data {
        let name = DER.sequence(
            DER.set(DER.sequence(DER.oid("2.5.4.3"), DER.utf8String(commonName))),
            DER.set(DER.sequence(DER.oid("2.5.4.10"), DER.utf8String(organization)))
        )
        let algorithm = DER.sequence(DER.oid(ecdsaWithSHA256))
        let publicKeyInfo = DER.sequence(
            DER.sequence(DER.oid(ecPublicKey), DER.oid(prime256v1)),
            DER.bitString(Array(key.publicKey.x963Representation))
        )
        let extensions = DER.sequence(
            // Basic constraints: not a CA. Critical.
            DER.sequence(DER.oid("2.5.29.19"), DER.boolTrue, DER.octetString(DER.sequence())),
            // Key usage: digital signature (bit 0). Critical.
            DER.sequence(DER.oid("2.5.29.15"), DER.boolTrue, DER.octetString(DER.bitString([0x80], unusedBits: 7))),
            // Extended key usage: TLS server and client.
            DER.sequence(DER.oid("2.5.29.37"), DER.octetString(DER.sequence(DER.oid("1.3.6.1.5.5.7.3.1"), DER.oid("1.3.6.1.5.5.7.3.2"))))
        )
        let tbs = DER.sequence(
            DER.element(0xA0, DER.integer([2])),
            DER.integer(serial),
            algorithm,
            name,
            DER.sequence(DER.time(now.addingTimeInterval(-3600)), DER.time(now.addingTimeInterval(10 * 365 * 24 * 3600))),
            name,
            publicKeyInfo,
            DER.element(0xA3, extensions)
        )
        let signature = try key.signature(for: Data(tbs)).derRepresentation
        return Data(DER.sequence(tbs, algorithm, DER.bitString(Array(signature))))
    }
}
