import Foundation

/// One accepted incoming LocalSend transfer: prepared, then each file uploaded with its token, then
/// done — or cancelled by the sender, or expired when uploads stall. Pure, so every rule is tested.
struct ReceiveSession: Sendable {
    enum State: Equatable, Sendable {
        case receiving
        case finished
        case cancelled
        case expired
    }

    enum Rejection: Error, Equatable {
        /// 400: missing parameters.
        case missingParameters
        /// 403: wrong session, file, token or IP address.
        case forbidden
        /// 409: this file already arrived, or the session is over.
        case conflict

        var status: Int {
            switch self {
            case .missingParameters: 400
            case .forbidden: 403
            case .conflict: 409
            }
        }
    }

    struct IncomingFile: Sendable {
        var info: LocalSend.FileInfo
        var token: String
        var isReceived = false
        var isUploading = false
    }

    /// Uploads that go quiet for this long end the session.
    static let stallTimeout: TimeInterval = 120

    let id: String
    let sender: LocalSend.DeviceInfo
    let senderAddress: String
    private(set) var files: [String: IncomingFile]
    private(set) var state = State.receiving
    private(set) var lastActivity: Date

    init(id: String, sender: LocalSend.DeviceInfo, senderAddress: String, files: [LocalSend.FileInfo], tokens: [String: String], now: Date) {
        self.id = id
        self.sender = sender
        self.senderAddress = senderAddress
        var incoming: [String: IncomingFile] = [:]
        for file in files {
            if let token = tokens[file.id] {
                incoming[file.id] = IncomingFile(info: file, token: token)
            }
        }
        self.files = incoming
        lastActivity = now
    }

    /// The tokens to answer `prepare-upload` with.
    var tokens: [String: String] {
        files.mapValues(\.token)
    }

    var totalSize: Int64 {
        files.values.reduce(0) { $0 + $1.info.size }
    }

    var receivedCount: Int {
        files.values.filter(\.isReceived).count
    }

    /// Checks an `upload` request and marks that file as arriving.
    mutating func beginUpload(sessionID: String?, fileID: String?, token: String?, from address: String?, now: Date) -> Result<LocalSend.FileInfo, Rejection> {
        guard let sessionID, let fileID, let token else { return .failure(.missingParameters) }
        guard sessionID == id, address == senderAddress, let file = files[fileID], file.token == token else { return .failure(.forbidden) }
        guard state == .receiving, !file.isReceived, !file.isUploading else { return .failure(.conflict) }
        files[fileID]?.isUploading = true
        lastActivity = now
        return .success(file.info)
    }

    /// Bytes are still arriving.
    mutating func touch(now: Date) {
        lastActivity = now
    }

    /// The file arrived whole. Once every file has, the session is finished.
    mutating func finishUpload(fileID: String, now: Date) {
        guard files[fileID] != nil, state == .receiving else { return }
        files[fileID]?.isUploading = false
        files[fileID]?.isReceived = true
        lastActivity = now
        if files.values.allSatisfy(\.isReceived) {
            state = .finished
        }
    }

    /// The upload failed part way; the sender may try that file again.
    mutating func failUpload(fileID: String) {
        files[fileID]?.isUploading = false
    }

    /// The sender called `cancel`. Only the sender's own address can.
    mutating func cancel(sessionID: String?, from address: String?) -> Bool {
        guard sessionID == id, address == senderAddress, state == .receiving else { return false }
        state = .cancelled
        return true
    }

    /// Ends the session if it's been quiet for `stallTimeout`. Returns whether it just expired.
    mutating func expireIfStalled(now: Date) -> Bool {
        guard state == .receiving, now.timeIntervalSince(lastActivity) >= Self.stallTimeout else { return false }
        state = .expired
        return true
    }

    var isActive: Bool { state == .receiving }
}

/// The rules for answering `prepare-upload`, before the user is asked anything.
enum ReceiveRules {
    /// The default largest transfer Cheese accepts.
    static let defaultMaxBytes: Int64 = 10 * 1_000_000_000
    /// `prepare-upload` bodies larger than this are refused.
    static let maxPrepareBytes = 1 << 20

    enum Decision: Equatable {
        /// Ask the user (or accept straight away for a trusted device).
        case ask
        /// Refuse with this status.
        case refuse(Int)
    }

    static func check(_ request: LocalSend.PrepareUploadRequest, hasActiveSession: Bool, maxBytes: Int64) -> Decision {
        guard !request.files.isEmpty else { return .refuse(400) }
        guard request.files.allSatisfy({ key, file in key == file.id && file.size >= 0 }) else { return .refuse(400) }
        guard !hasActiveSession else { return .refuse(409) }
        let total = request.files.values.reduce(Int64(0)) { $0 + $1.size }
        guard total <= maxBytes else { return .refuse(403) }
        return .ask
    }

    /// "Pixel 8 wants to send 3 files (24 MB)" / "…wants to send a message".
    static func summary(of request: LocalSend.PrepareUploadRequest) -> String {
        let alias = request.info.alias.isEmpty ? "A device" : request.info.alias
        let files = Array(request.files.values)
        if files.allSatisfy(\.isMessage) {
            return files.count == 1 ? "\(alias) wants to send a message" : "\(alias) wants to send \(files.count) messages"
        }
        let size = ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file)
        let noun = files.count == 1 ? "1 file" : "\(files.count) files"
        return "\(alias) wants to send \(noun) (\(size))"
    }

    /// 128-bit random hex, for session IDs and file tokens.
    static func makeToken() -> String {
        ShareRules.makeToken()
    }
}
