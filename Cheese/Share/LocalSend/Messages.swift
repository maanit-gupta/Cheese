import Foundation

/// The LocalSend protocol's messages (v2.2, see docs/LOCALSEND.md), as they go over the wire.
enum LocalSend {
    static let protocolVersion = "2.2"
    static let port: UInt16 = 53317
    static let multicastAddress = "224.0.0.167"
    static let apiPrefix = "/api/localsend/v2"

    enum DeviceType: String, Codable, Sendable {
        case mobile, desktop, web, headless, server

        /// Unknown values fall back to desktop, as the official app does.
        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = DeviceType(rawValue: raw) ?? .desktop
        }
    }

    enum Transport: String, Codable, Sendable {
        case http, https
    }

    /// A device's description: the multicast announcement, `register`, and `info`.
    struct DeviceInfo: Codable, Equatable, Sendable {
        var alias: String
        var version: String
        var deviceModel: String?
        var deviceType: DeviceType?
        var fingerprint: String
        var port: Int?
        var transport: Transport?
        var download: Bool?
        /// Set only on multicast messages: true asks others to answer.
        var announce: Bool?

        enum CodingKeys: String, CodingKey {
            case alias, version, deviceModel, deviceType, fingerprint, port
            case transport = "protocol"
            case download, announce
        }
    }

    struct FileMetadata: Codable, Equatable, Sendable {
        var modified: String?
        var accessed: String?
    }

    struct FileInfo: Codable, Equatable, Sendable {
        var id: String
        var fileName: String
        var size: Int64
        var fileType: String
        var sha256: String?
        var preview: String?
        var metadata: FileMetadata?

        /// LocalSend sends a text message as a single text file whose content is in `preview`.
        var isMessage: Bool {
            (fileType == "text/plain" || fileType == "text") && preview != nil
        }
    }

    struct PrepareUploadRequest: Codable, Equatable, Sendable {
        var info: DeviceInfo
        var files: [String: FileInfo]
    }

    struct PrepareUploadResponse: Codable, Equatable, Sendable {
        var sessionId: String
        /// File ID → the token its upload must carry.
        var files: [String: String]
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    static func encode(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    }
}
