import Foundation
import UniformTypeIdentifiers
import os

/// Something waiting to be sent: a file, or text (a link is text).
struct OutgoingItem: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case file(URL)
        case text(String)
    }

    var id = UUID()
    var content: Content

    static func file(_ url: URL) -> OutgoingItem { OutgoingItem(content: .file(url)) }
    static func text(_ text: String) -> OutgoingItem { OutgoingItem(content: .text(text)) }

    var name: String {
        switch content {
        case let .file(url): url.lastPathComponent
        case let .text(text):
            (text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text).trimmingCharacters(in: .whitespaces)
        }
    }

    var size: Int64 {
        switch content {
        case let .file(url): Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        case let .text(text): Int64(text.utf8.count)
        }
    }

    var mimeType: String {
        switch content {
        case let .file(url): UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        case .text: "text/plain"
        }
    }

    var symbol: String {
        switch content {
        case .file: "doc"
        case let .text(text): text.hasPrefix("http://") || text.hasPrefix("https://") ? "link" : "text.quote"
        }
    }
}

enum SendError: LocalizedError, Equatable {
    case declined
    case busy
    case identityMismatch
    case refused(Int)
    case nothingToSend

    var errorDescription: String? {
        switch self {
        case .declined: "The device declined."
        case .busy: "The device is busy with another transfer."
        case .identityMismatch: "The device's identity didn't match what it announced, so nothing was sent."
        case let .refused(status): "The device refused the transfer (\(status))."
        case .nothingToSend: "There's nothing to send."
        }
    }
}

/// Sends files and text to a LocalSend device: `prepare-upload`, then each accepted file, then done.
/// Cancelling the task calls `cancel` on the device.
enum LocalSendSender {
    /// The `prepare-upload` file list: text goes as a text file whose content is in `preview`.
    static func fileInfos(for items: [OutgoingItem]) -> [String: LocalSend.FileInfo] {
        var files: [String: LocalSend.FileInfo] = [:]
        for item in items {
            let id = item.id.uuidString
            switch item.content {
            case let .file(url):
                files[id] = LocalSend.FileInfo(id: id, fileName: url.lastPathComponent, size: item.size, fileType: item.mimeType)
            case let .text(text):
                files[id] = LocalSend.FileInfo(id: id, fileName: "\(id).txt", size: item.size, fileType: "text/plain", preview: text)
            }
        }
        return files
    }

    @concurrent
    static func send(
        _ items: [OutgoingItem],
        to peer: LocalSendPeer,
        as info: LocalSend.DeviceInfo,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard !items.isEmpty else { throw SendError.nothingToSend }
        let files = fileInfos(for: items)
        let request = LocalSend.PrepareUploadRequest(info: info, files: files)
        let prepared = try await HTTPClient.send(
            "POST", to: peer.endpoint, target: LocalSend.apiPrefix + "/prepare-upload",
            headers: [("Content-Type", "application/json")], body: .data(LocalSend.encode(request)),
            // The device waits for its user to accept.
            timeout: .seconds(120)
        )
        if peer.transport == .https, !TLSIdentity.matches(prepared.peerFingerprint, announced: peer.fingerprint) {
            throw SendError.identityMismatch
        }
        switch prepared.status {
        case 200: break
        // Finished: nothing to upload (messages).
        case 204:
            onProgress(1)
            return
        case 403: throw SendError.declined
        case 409: throw SendError.busy
        default: throw SendError.refused(prepared.status)
        }
        guard let response = LocalSend.decode(LocalSend.PrepareUploadResponse.self, from: prepared.body) else {
            throw HTTPClientError.malformedResponse
        }

        let accepted = items.filter { response.files[$0.id.uuidString] != nil }
        let total = max(1, accepted.reduce(Int64(0)) { $0 + $1.size })
        var done: Int64 = 0
        do {
            for item in accepted {
                try Task.checkCancellation()
                let id = item.id.uuidString
                guard let token = response.files[id] else { continue }
                let target = LocalSend.apiPrefix + "/upload?" + query(["sessionId": response.sessionId, "fileId": id, "token": token])
                let body: HTTPResponse.Body = switch item.content {
                case let .file(url): .file(url)
                case let .text(text): .data(Data(text.utf8))
                }
                let base = done
                let uploaded = try await HTTPClient.send(
                    "POST", to: peer.endpoint, target: target,
                    headers: [("Content-Type", item.mimeType)], body: body, timeout: .seconds(60)
                ) { sent in
                    onProgress(Double(base + sent) / Double(total))
                }
                guard (200..<300).contains(uploaded.status) else { throw SendError.refused(uploaded.status) }
                done += item.size
                onProgress(Double(done) / Double(total))
            }
        } catch {
            // Tell the device, so it doesn't wait for files that won't come.
            _ = try? await HTTPClient.send(
                "POST", to: peer.endpoint, target: LocalSend.apiPrefix + "/cancel?" + query(["sessionId": response.sessionId]), timeout: .seconds(5)
            )
            throw error
        }
    }

    static func query(_ parameters: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return parameters.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}
