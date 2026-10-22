import Foundation
import os

/// How the user answered "Pixel 8 wants to send 3 files".
enum ReceiveAnswer: Sendable {
    case decline
    case accept
    case alwaysAccept
}

/// Answers LocalSend devices sending to this Mac: `prepare-upload` (asking the user unless the device
/// is trusted), `upload` and `cancel`. One transfer at a time; files go to the destination folder,
/// messages to the clipboard.
@MainActor
final class LocalSendReceiver {
    struct Hooks {
        var destination: @MainActor () -> URL
        var maxBytes: @MainActor () -> Int64
        var ask: @MainActor (_ summary: String, _ sender: LocalSend.DeviceInfo) async -> ReceiveAnswer
        var trustStore: TrustStore
        var onText: @MainActor (_ text: String, _ from: String) -> Void
        var onFilesReceived: @MainActor (_ files: [URL], _ from: String) -> Void
        var onProblem: @MainActor (_ message: String) -> Void
    }

    private let hooks: Hooks
    private var session: ReceiveSession?
    private var isAsking = false
    private var received: [URL] = []
    private var partials: [String: URL] = [:]
    private var stallTask: Task<Void, Never>?

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    var isReceiving: Bool { session?.isActive == true }

    // MARK: prepare-upload

    func prepareUpload(_ request: HTTPRequest, body: HTTPRequestBody) async -> HTTPResponse {
        guard request.method == "POST" else { return .status(405) }
        guard !isAsking, session?.isActive != true else { return .status(409) }
        guard let data = try? await body.collect(limit: ReceiveRules.maxPrepareBytes),
              let prepare = LocalSend.decode(LocalSend.PrepareUploadRequest.self, from: data),
              let address = request.remoteAddress
        else { return .status(400) }
        if case let .refuse(status) = ReceiveRules.check(prepare, hasActiveSession: isAsking || isReceiving, maxBytes: hooks.maxBytes()) {
            return .status(status)
        }

        var answer = ReceiveAnswer.accept
        if !hooks.trustStore.isTrusted(prepare.info.fingerprint) {
            isAsking = true
            answer = await hooks.ask(ReceiveRules.summary(of: prepare), prepare.info)
            isAsking = false
        }
        switch answer {
        case .decline:
            return .status(403)
        case .alwaysAccept:
            hooks.trustStore.trust(fingerprint: prepare.info.fingerprint, alias: prepare.info.alias)
        case .accept:
            break
        }

        let files = Array(prepare.files.values)
        if files.allSatisfy(\.isMessage) {
            for file in files.sorted(by: { $0.fileName < $1.fileName }) {
                if let text = file.preview {
                    hooks.onText(text, prepare.info.alias)
                }
            }
            return HTTPResponse(status: 204)
        }

        let id = ReceiveRules.makeToken()
        let tokens = Dictionary(uniqueKeysWithValues: files.map { ($0.id, ReceiveRules.makeToken()) })
        session = ReceiveSession(id: id, sender: prepare.info, senderAddress: address, files: files, tokens: tokens, now: .now)
        received = []
        watchForStalls()
        Logger.share.info("Receiving \(files.count) file(s) from a LocalSend device")
        return .json(LocalSend.PrepareUploadResponse(sessionId: id, files: tokens))
    }

    // MARK: upload

    func upload(_ request: HTTPRequest, body: HTTPRequestBody) async -> HTTPResponse {
        guard request.method == "POST" else { return .status(405) }
        guard var current = session else { return .status(409) }
        let fileID = request.query["fileId"]
        let begun = current.beginUpload(
            sessionID: request.query["sessionId"], fileID: fileID, token: request.query["token"],
            from: request.remoteAddress, now: .now
        )
        session = current
        guard case let .success(info) = begun, let fileID else {
            if case let .failure(rejection) = begun { return .status(rejection.status) }
            return .status(400)
        }

        let folder = hooks.destination()
        let partial = ReceivedFileWriter.partialURL(in: folder)
        partials[fileID] = partial
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await ReceivedFileWriter.write(
                body, to: partial, expectedSize: info.size, maxSize: hooks.maxBytes(), sha256: info.sha256
            ) { [weak self] _ in
                await self?.touch()
            }
            // The session may have been cancelled while the bytes arrived.
            guard session?.id == current.id, session?.isActive == true else {
                discardPartial(fileID)
                return .status(409)
            }
            let final = try ReceivedFileWriter.finish(partial, named: info.fileName, in: folder)
            partials[fileID] = nil
            received.append(final)
            session?.finishUpload(fileID: fileID, now: .now)
            if session?.state == .finished {
                finishSession()
            }
            return HTTPResponse(status: 200)
        } catch {
            Logger.share.error("Receiving a file failed: \(error.localizedDescription, privacy: .public)")
            discardPartial(fileID)
            session?.failUpload(fileID: fileID)
            switch error as? ReceiveError {
            case .checksumMismatch: return .status(422)
            case .tooLarge, .incomplete: return .status(400)
            case nil: return .status(500)
            }
        }
    }

    // MARK: cancel

    func cancel(_ request: HTTPRequest) -> HTTPResponse {
        guard var current = session, current.cancel(sessionID: request.query["sessionId"], from: request.remoteAddress) else {
            return .status(request.query["sessionId"] == nil ? 400 : 403)
        }
        session = current
        hooks.onProblem("\(current.sender.alias) cancelled the transfer")
        endSession()
        return HTTPResponse(status: 200)
    }

    /// Cheese Share stopped: whatever was arriving is abandoned.
    func stop() {
        if session?.isActive == true {
            endSession()
        }
        session = nil
    }

    // MARK: Session lifetime

    private func touch() {
        session?.touch(now: .now)
    }

    private func watchForStalls() {
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, var current = self.session else { return }
                if current.expireIfStalled(now: .now) {
                    self.session = current
                    self.hooks.onProblem("The transfer from \(current.sender.alias) stalled")
                    self.endSession()
                    return
                }
            }
        }
    }

    private func finishSession() {
        if let alias = session?.sender.alias, !received.isEmpty {
            hooks.onFilesReceived(received, alias)
        }
        stallTask?.cancel()
        session = nil
        received = []
    }

    /// Ends a cancelled or stalled session: partial files go, finished ones stay and are reported.
    private func endSession() {
        for fileID in Array(partials.keys) {
            discardPartial(fileID)
        }
        finishSession()
    }

    private func discardPartial(_ fileID: String) {
        if let partial = partials.removeValue(forKey: fileID) {
            try? FileManager.default.removeItem(at: partial)
        }
    }
}
