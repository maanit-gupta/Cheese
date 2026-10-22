import Foundation
import Network
import os

/// A LocalSend device found on the network.
struct LocalSendPeer: Identifiable, Equatable, Sendable {
    var fingerprint: String
    var alias: String
    var deviceModel: String?
    var deviceType: LocalSend.DeviceType
    var address: String
    var port: UInt16
    var transport: LocalSend.Transport

    var id: String { fingerprint }

    var endpoint: HTTPClient.Endpoint {
        HTTPClient.Endpoint(host: address, port: port, usesTLS: transport == .https)
    }

    init?(info: LocalSend.DeviceInfo, address: String, fallbackPort: UInt16 = LocalSend.port) {
        guard !info.fingerprint.isEmpty, !address.isEmpty else { return nil }
        fingerprint = info.fingerprint
        alias = info.alias.isEmpty ? "Unknown device" : info.alias
        deviceModel = info.deviceModel
        deviceType = info.deviceType ?? .desktop
        self.address = address
        port = info.port.flatMap { UInt16(exactly: $0) } ?? fallbackPort
        transport = info.transport ?? .https
    }

    /// The SF Symbol for its tile.
    var symbol: String {
        switch deviceType {
        case .mobile: "iphone"
        case .web: "globe"
        case .headless, .server: "server.rack"
        case .desktop: deviceModel?.localizedCaseInsensitiveContains("book") == true || deviceModel?.localizedCaseInsensitiveContains("laptop") == true ? "laptopcomputer" : "desktopcomputer"
        }
    }
}

/// LocalSend's multicast discovery: announces this Mac on 224.0.0.167:53317, answers other
/// devices' announcements (by `register`, falling back to multicast), and reports who it finds.
/// Runs only while Cheese Share is listening.
@MainActor
final class LocalSendDiscovery {
    enum Status: Equatable {
        case idle
        case searching
        /// macOS refused (usually Local Network permission), with a message for the user.
        case unavailable(String)
    }

    var onPeer: (LocalSendPeer) -> Void = { _ in }
    var onStatus: (Status) -> Void = { _ in }
    private var group: NWConnectionGroup?
    private var info: () -> LocalSend.DeviceInfo = { LocalSend.DeviceInfo(alias: "", version: LocalSend.protocolVersion, fingerprint: "") }

    func start(info: @escaping () -> LocalSend.DeviceInfo) {
        self.info = info
        guard group == nil else {
            announce()
            return
        }
        let multicast: NWMulticastGroup
        do {
            multicast = try NWMulticastGroup(for: [.hostPort(host: NWEndpoint.Host(LocalSend.multicastAddress), port: NWEndpoint.Port(rawValue: LocalSend.port) ?? .any)])
        } catch {
            onStatus(.unavailable(error.localizedDescription))
            return
        }
        let parameters = NWParameters.udp
        // LocalSend itself may be running on this Mac on the same port.
        parameters.allowLocalEndpointReuse = true
        let group = NWConnectionGroup(with: multicast, using: parameters)
        group.setReceiveHandler(maximumMessageSize: 16_384, rejectOversizedMessages: true) { [weak self] message, content, _ in
            let address = message.remoteEndpoint.flatMap(Self.host(of:))
            MainActor.assumeIsolated {
                guard let content, let address else { return }
                self?.received(content, from: address)
            }
        }
        group.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(state) }
        }
        self.group = group
        onStatus(.searching)
        group.start(queue: .main)
    }

    func stop() {
        group?.stateUpdateHandler = nil
        group?.cancel()
        group = nil
        onStatus(.idle)
    }

    /// Tells everyone on the network we're here; they answer with `register`.
    func announce() {
        var message = info()
        message.announce = true
        group?.send(content: LocalSend.encode(message)) { error in
            if let error {
                Logger.share.debug("Announce failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A device registered with us over HTTP.
    func registered(_ info: LocalSend.DeviceInfo, from address: String) {
        guard info.fingerprint != self.info().fingerprint, let peer = LocalSendPeer(info: info, address: address) else { return }
        onPeer(peer)
    }

    private func stateChanged(_ state: NWConnectionGroup.State) {
        switch state {
        case .ready:
            onStatus(.searching)
            announce()
        case let .waiting(error), let .failed(error):
            Logger.share.error("Discovery unavailable: \(error.localizedDescription, privacy: .public)")
            onStatus(.unavailable(Self.explanation(for: error)))
        default:
            break
        }
    }

    static func explanation(for error: NWError) -> String {
        if case let .dns(code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
            return "Cheese can't see nearby devices — allow Local Network in System Settings."
        }
        if case let .posix(code) = error, code == .EHOSTUNREACH || code == .EPERM || code == .EACCES {
            return "Cheese can't see nearby devices — allow Local Network in System Settings."
        }
        return "Cheese can't look for nearby devices: \(error.localizedDescription)"
    }

    private func received(_ data: Data, from address: String) {
        guard let message = LocalSend.decode(LocalSend.DeviceInfo.self, from: data) else { return }
        let ours = info()
        guard message.fingerprint != ours.fingerprint, let peer = LocalSendPeer(info: message, address: address) else { return }
        onPeer(peer)
        guard message.announce == true else { return }
        // Answer by registering with it over HTTP; if that fails, answer on multicast.
        var answer = ours
        answer.announce = nil
        let body = LocalSend.encode(answer)
        Task { [weak self] in
            do {
                _ = try await HTTPClient.send(
                    "POST", to: peer.endpoint, target: LocalSend.apiPrefix + "/register",
                    headers: [("Content-Type", "application/json")], body: .data(body), timeout: .seconds(5)
                )
            } catch {
                var multicastAnswer = ours
                multicastAnswer.announce = false
                self?.group?.send(content: LocalSend.encode(multicastAnswer)) { _ in }
            }
        }
    }

    nonisolated private static func host(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case let .ipv4(address): return "\(address)".split(separator: "%").first.map(String.init)
        case let .ipv6(address): return "\(address)".split(separator: "%").first.map(String.init)
        case let .name(name, _): return name
        @unknown default: return nil
        }
    }
}
