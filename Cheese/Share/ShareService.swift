import AppKit
import Foundation
import os

/// Runs Cheese Share while it's wanted: the HTTP server (LocalSend API and the browser page),
/// LocalSend discovery, and outgoing transfers. Nothing listens until the Share panel opens; it all
/// stops `idleLifetime` after the panel closes, or right away when the module is turned off.
@MainActor
@Observable
final class ShareService {
    enum Listening: Equatable {
        case stopped
        case starting
        case listening(address: String, port: UInt16)
        case unavailable(String)
    }

    /// One device's outgoing transfer.
    struct Transfer: Equatable {
        enum State: Equatable {
            case waiting
            case sending(Double)
            case done
            case failed(String)
        }

        var state: State
        var itemCount: Int
    }

    struct Hooks {
        /// Asks whether to accept a LocalSend device's files.
        var ask: @MainActor (_ summary: String, _ sender: LocalSend.DeviceInfo) async -> ReceiveAnswer
        /// Received text: into clipboard history (or just the clipboard), with a toast.
        var receivedText: @MainActor (_ text: String, _ from: String) -> Void
        /// Shows or clears the menu bar indicator.
        var setListening: @MainActor (Bool) -> Void
        /// The address to listen on; the LAN address unless a test says otherwise.
        var address: @MainActor () -> String? = { LANAddress.current() }
        /// The TLS identity; the Keychain's unless a test says otherwise.
        var identity: @MainActor () -> ShareIdentity? = { TLSIdentity.loadOrCreate() }
        /// How long Share keeps listening after the panel closes.
        var idleLifetime: Duration = ShareService.idleLifetime
    }

    nonisolated static let idleLifetime: Duration = .seconds(10 * 60)

    private(set) var listening = Listening.stopped
    /// LocalSend transfers use HTTPS (false only when the Keychain wouldn't hold a certificate).
    private(set) var isEncrypted = false
    /// The plain-HTTP port of the browser link's page; browsers refuse self-signed certificates.
    private(set) var browserPort: UInt16?
    private(set) var peers: [LocalSendPeer] = []
    private(set) var discoveryProblem: String?
    private(set) var transfers: [LocalSendPeer.ID: Transfer] = [:]
    /// Staged to share: offered on the browser link's page, and sent to a device with one click.
    /// Handed in from a drop, the Shelf, the clipboard or the macOS Share menu.
    private(set) var staged: [OutgoingItem] = []

    @ObservationIgnored private let hooks: Hooks
    @ObservationIgnored private let trustStore = TrustStore()
    @ObservationIgnored private var transferTasks: [LocalSendPeer.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private let discovery = LocalSendDiscovery()
    @ObservationIgnored private var identity: ShareIdentity?
    @ObservationIgnored private lazy var receiver = LocalSendReceiver(hooks: LocalSendReceiver.Hooks(
        destination: { Preferences().shareDestination },
        maxBytes: { Preferences().shareMaxBytes },
        ask: { [hooks] summary, sender in await hooks.ask(summary, sender) },
        trustStore: trustStore,
        onText: { [hooks] text, from in hooks.receivedText(text, from) },
        onFilesReceived: { files, from in Self.notifyReceived(files, from: from) },
        onProblem: { message in CheeseToast.show(message, systemImage: "exclamationmark.triangle.fill") }
    ))
    @ObservationIgnored private(set) lazy var browser = BrowserTransfer(hooks: BrowserTransfer.Hooks(
        destination: { Preferences().shareDestination },
        maxBytes: { Preferences().shareMaxBytes },
        onText: { [hooks] text in hooks.receivedText(text, "your phone") },
        onFileReceived: { file in Self.notifyReceived([file], from: "your phone") }
    ))
    /// LocalSend's API, over HTTPS when there's a certificate.
    @ObservationIgnored private lazy var server: HTTPServer = makeServer { [weak self] request, body in
        await self?.routeLocalSend(request, body: body) ?? .status(404)
    }
    /// The browser link's page, over plain HTTP.
    @ObservationIgnored private lazy var browserServer: HTTPServer = makeServer { [weak self] request, body in
        await self?.routeBrowser(request, body: body) ?? .status(404)
    }

    private func makeServer(_ handler: @escaping HTTPServer.Handler) -> HTTPServer {
        let server = HTTPServer(handler: handler)
        server.onFailure = { [weak self] reason in
            self?.stop()
            self?.listening = .unavailable(reason)
        }
        return server
    }

    init(hooks: Hooks) {
        self.hooks = hooks
        discovery.onPeer = { [weak self] peer in self?.found(peer) }
        discovery.onStatus = { [weak self] status in
            if case let .unavailable(message) = status {
                self?.discoveryProblem = message
            } else {
                self?.discoveryProblem = nil
            }
        }
    }

    var isListening: Bool {
        if case .listening = listening { return true }
        return false
    }

    /// The link phones and browsers open, shown as a QR code in the Share panel.
    var browserURL: URL? {
        guard case let .listening(address, _) = listening, let browserPort else { return nil }
        return browser.url(address: address, port: browserPort)
    }

    /// What this Mac tells LocalSend devices about itself.
    var deviceInfo: LocalSend.DeviceInfo {
        let port = if case let .listening(_, port) = listening { Int(port) } else { Int(LocalSend.port) }
        return LocalSend.DeviceInfo(
            alias: Preferences().shareDeviceName,
            version: LocalSend.protocolVersion,
            deviceModel: TLSIdentity.deviceModel,
            deviceType: .desktop,
            fingerprint: identity?.fingerprint ?? TLSIdentity.fingerprint(),
            port: port,
            transport: identity == nil ? .http : .https,
            download: false
        )
    }

    // MARK: Lifetime

    /// The panel opened: start listening (if needed) and keep going until it closes.
    func panelOpened() {
        idleTask?.cancel()
        idleTask = nil
        browser.expiresAt = nil
        if isListening {
            discovery.announce()
            return
        }
        Task { await start() }
    }

    /// The panel closed: stop after `idleLifetime` unless it opens again, or something is still moving.
    func panelClosed() {
        idleTask?.cancel()
        let lifetime = hooks.idleLifetime.components
        browser.expiresAt = .now.addingTimeInterval(TimeInterval(lifetime.seconds) + TimeInterval(lifetime.attoseconds) / 1e18)
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: self?.hooks.idleLifetime ?? Self.idleLifetime)
            guard !Task.isCancelled, let self else { return }
            if self.receiver.isReceiving || !self.transferTasks.isEmpty {
                // Finish what's moving first; check again later.
                self.panelClosed()
            } else {
                self.stop()
            }
        }
    }

    private func start() async {
        guard listening == .stopped || { if case .unavailable = listening { return true } else { return false } }() else { return }
        guard let address = hooks.address() else {
            listening = .unavailable("Not on a local network. Connect to Wi-Fi to share with nearby devices.")
            return
        }
        listening = .starting
        if identity == nil {
            identity = hooks.identity()
        }
        isEncrypted = identity != nil
        discovery.identity = identity
        do {
            let port = try await server.start(on: address, preferredPort: LocalSend.port, identity: identity?.secIdentity)
            browserPort = try await browserServer.start(on: address)
            listening = .listening(address: address, port: port)
            hooks.setListening(true)
            discovery.start { [weak self] in self?.deviceInfo ?? LocalSend.DeviceInfo(alias: "", version: "", fingerprint: "") }
            Logger.share.info("Cheese Share listening on port \(port)")
        } catch {
            listening = .unavailable(error.localizedDescription)
        }
    }

    /// Stops listening, discovery and transfers. The browser link stops working.
    func stop() {
        idleTask?.cancel()
        idleTask = nil
        for task in transferTasks.values {
            task.cancel()
        }
        transferTasks.removeAll()
        transfers.removeAll()
        receiver.stop()
        discovery.stop()
        server.stop()
        browserServer.stop()
        browserPort = nil
        browser.reset()
        staged.removeAll()
        peers.removeAll()
        listening = .stopped
        hooks.setListening(false)
        Logger.share.info("Cheese Share stopped")
    }

    // MARK: Devices

    /// A device turned up (from discovery, or a test).
    func found(_ peer: LocalSendPeer) {
        if let index = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[index] = peer
        } else {
            peers.append(peer)
            peers.sort { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
        }
    }

    // MARK: Sending

    func send(_ items: [OutgoingItem], to peer: LocalSendPeer) {
        guard !items.isEmpty, transferTasks[peer.id] == nil else { return }
        transfers[peer.id] = Transfer(state: .waiting, itemCount: items.count)
        let info = deviceInfo
        let identity = identity
        transferTasks[peer.id] = Task { [weak self] in
            do {
                try await LocalSendSender.send(items, to: peer, as: info, identity: identity) { fraction in
                    Task { @MainActor in self?.progress(fraction, for: peer.id) }
                }
                self?.finished(peer, error: nil)
            } catch is CancellationError {
                self?.finished(peer, error: CancellationError())
            } catch {
                self?.finished(peer, error: error)
            }
        }
    }

    func cancelTransfer(to peer: LocalSendPeer) {
        transferTasks[peer.id]?.cancel()
    }

    private func progress(_ fraction: Double, for id: LocalSendPeer.ID) {
        guard transferTasks[id] != nil else { return }
        transfers[id]?.state = .sending(min(max(fraction, 0), 1))
    }

    private func finished(_ peer: LocalSendPeer, error: (any Error)?) {
        transferTasks[peer.id] = nil
        switch error {
        case nil:
            transfers[peer.id]?.state = .done
            CheeseToast.show("Sent to \(peer.alias)", systemImage: "checkmark.circle.fill")
        case is CancellationError:
            transfers[peer.id] = nil
            return
        case let error?:
            Logger.share.error("Sending failed: \(error.localizedDescription, privacy: .public)")
            transfers[peer.id]?.state = .failed(error.localizedDescription)
        }
        // Clear the tile's status after a moment.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.transferTasks[peer.id] == nil {
                self?.transfers[peer.id] = nil
            }
        }
    }

    // MARK: Staging

    /// Adds items to share, skipping any already staged.
    func stage(_ items: [OutgoingItem]) {
        let new = items.filter { item in !staged.contains { $0.content == item.content } }
        staged.append(contentsOf: new)
        browser.offer(new)
    }

    func unstage(_ id: OutgoingItem.ID) {
        staged.removeAll { $0.id == id }
        browser.withdraw(id)
    }

    func clearStaged() {
        for item in staged {
            browser.withdraw(item.id)
        }
        staged.removeAll()
    }

    /// When the browser link stops working: nil while the Share panel is open.
    var linkExpiresAt: Date? { browser.expiresAt }

    // MARK: Trust

    var trustedDevices: [TrustedDevice] { trustStore.devices }

    // MARK: Routing

    private func routeBrowser(_ request: HTTPRequest, body: HTTPRequestBody) async -> HTTPResponse {
        browser.handles(request.path) ? await browser.handle(request, body: body) : .status(404)
    }

    private func routeLocalSend(_ request: HTTPRequest, body: HTTPRequestBody) async -> HTTPResponse {
        let api = LocalSend.apiPrefix
        switch request.path {
        case api + "/register":
            guard request.method == "POST" else { return .status(405) }
            guard let data = try? await body.collect(limit: 16_384),
                  let info = LocalSend.decode(LocalSend.DeviceInfo.self, from: data),
                  let address = request.remoteAddress
            else { return .status(400) }
            discovery.registered(info, from: address)
            var answer = deviceInfo
            answer.announce = nil
            return .json(answer)
        case api + "/info":
            var answer = deviceInfo
            answer.announce = nil
            return .json(answer)
        case api + "/prepare-upload":
            return await receiver.prepareUpload(request, body: body)
        case api + "/upload":
            return await receiver.upload(request, body: body)
        case api + "/cancel":
            return receiver.cancel(request)
        default:
            return .status(404)
        }
    }

    private static func notifyReceived(_ files: [URL], from sender: String) {
        let title = files.count == 1 ? "Received \(files[0].lastPathComponent)" : "Received \(files.count) files"
        CheeseNotifications.shared.post(title: title, body: "From \(sender), in \(files[0].deletingLastPathComponent().lastPathComponent)", reveal: files)
    }
}
