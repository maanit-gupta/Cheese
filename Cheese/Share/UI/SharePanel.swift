import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Share panel: nearby LocalSend devices and the Phone (scan QR) tile, with anything handed in
/// from the Shelf, the clipboard or the macOS Share menu waiting in a "Ready to send" strip.
/// Opening it starts Cheese Share; closing it starts the 10-minute countdown to stopping.
@MainActor
final class SharePanelController {
    private let service: ShareService
    private let model: SharePanelModel
    private var panel: CheesePanel?

    /// - Parameter clipboardItems: the current clipboard as things to send.
    init(service: ShareService, clipboardItems: @escaping @MainActor () -> [OutgoingItem]) {
        self.service = service
        model = SharePanelModel(service: service, clipboardItems: clipboardItems)
        model.onClose = { [weak self] in self?.close() }
    }

    var isShown: Bool { panel?.isVisible ?? false }

    /// Opens the panel, adding `items` to the ready strip.
    func show(ready items: [OutgoingItem] = []) {
        if !items.isEmpty {
            service.ready = items
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        model.mode = .devices
        panel.present(at: .centered)
        service.panelOpened()
    }

    func close() {
        guard panel?.isVisible == true else { return }
        panel?.dismiss()
        service.panelClosed()
    }

    private func makePanel() -> CheesePanel {
        var behavior = CheesePanel.Behavior()
        // Stays open while files are dragged in from Finder.
        behavior.dismissesOnOutsideClick = false
        behavior.isMovable = true
        behavior.level = .floating
        let panel = CheesePanel(rootView: SharePanelView(model: model), behavior: behavior)
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }
}

@MainActor
@Observable
final class SharePanelModel {
    enum Mode {
        case devices
        case phone
    }

    let service: ShareService
    var mode = Mode.devices
    @ObservationIgnored let clipboardItems: @MainActor () -> [OutgoingItem]
    @ObservationIgnored var onClose: () -> Void = {}

    init(service: ShareService, clipboardItems: @escaping @MainActor () -> [OutgoingItem]) {
        self.service = service
        self.clipboardItems = clipboardItems
    }

    /// Clicking a device sends what's ready, or asks for files when nothing is.
    func activate(_ peer: LocalSendPeer) {
        if service.transfers[peer.id]?.state == .waiting || isSending(to: peer) {
            return
        }
        if service.ready.isEmpty {
            chooseFiles { [weak self] items in self?.service.send(items, to: peer) }
        } else {
            service.send(service.ready, to: peer)
            service.ready = []
        }
    }

    func isSending(to peer: LocalSendPeer) -> Bool {
        if case .sending = service.transfers[peer.id]?.state { return true }
        return service.transfers[peer.id]?.state == .waiting
    }

    func sendClipboard(to peer: LocalSendPeer) {
        let items = clipboardItems()
        guard !items.isEmpty else {
            CheeseToast.show("The clipboard is empty", systemImage: "clipboard")
            return
        }
        service.send(items, to: peer)
    }

    func openPhone(adding items: [OutgoingItem] = []) {
        var offered = items
        if offered.isEmpty {
            offered = service.ready
            service.ready = []
        }
        service.offerToPhone(offered)
        mode = .phone
    }

    func chooseFiles(_ then: @escaping ([OutgoingItem]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        then(panel.urls.map(OutgoingItem.file))
    }

    func status(of peer: LocalSendPeer) -> String? {
        switch service.transfers[peer.id]?.state {
        case nil: nil
        case .waiting: "Waiting for \(peer.alias)…"
        case let .sending(fraction): "Sending… \(Int(fraction * 100))%"
        case .done: "Sent"
        case let .failed(message): message
        }
    }
}

private struct SharePanelView: View {
    @Bindable var model: SharePanelModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.mode {
            case .devices: DevicesView(model: model)
            case .phone: PhoneView(model: model)
            }
        }
        .frame(width: 560, height: 440)
        .cheesePanelBackground()
    }

    private var header: some View {
        CheeseToolbar {
            if model.mode == .phone {
                CheeseIconButton(symbol: "chevron.left", help: "Back") { model.mode = .devices }
            }
            Image(systemName: ModuleID.share.symbol)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("Cheese Share")
                    .font(DesignTokens.Typography.heading)
                Text(statusLine)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } trailing: {
            CheeseIconButton(symbol: "xmark", help: "Close") { model.onClose() }
        }
    }

    private var statusLine: String {
        switch model.service.listening {
        case .stopped, .starting: "Starting…"
        case .listening:
            "Visible as \(Preferences().shareDeviceName)" + (model.service.isEncrypted ? " · encrypted" : " · unencrypted")
        case let .unavailable(message): message
        }
    }
}

private struct DevicesView: View {
    let model: SharePanelModel
    private let columns = [GridItem(.adaptive(minimum: 116), spacing: DesignTokens.Spacing.medium)]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            if !model.service.ready.isEmpty {
                ReadyStrip(model: model)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.medium) {
                    PhoneTile(model: model)
                    ForEach(model.service.peers) { peer in
                        DeviceTile(model: model, peer: peer)
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.xxSmall)
            }
            footer
        }
        .padding(DesignTokens.Spacing.xLarge)
    }

    @ViewBuilder private var footer: some View {
        if let problem = model.service.discoveryProblem {
            Label(problem, systemImage: "wifi.exclamationmark")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.orange)
        } else if model.service.isListening {
            Label(
                model.service.peers.isEmpty
                    ? "Looking for devices running LocalSend on this network…"
                    : "Drop files on a device, or click it to send.",
                systemImage: "dot.radiowaves.left.and.right"
            )
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ReadyStrip: View {
    let model: SharePanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
            CheeseSectionHeader(title: "Ready to send", symbol: "tray.and.arrow.up") {
                Button("Clear") { model.service.ready = [] }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            ScrollView(.horizontal) {
                HStack(spacing: DesignTokens.Spacing.xSmall) {
                    ForEach(model.service.ready) { item in
                        Label(item.name, systemImage: item.symbol)
                            .font(DesignTokens.Typography.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 160)
                            .padding(.horizontal, DesignTokens.Spacing.small)
                            .padding(.vertical, DesignTokens.Spacing.xxSmall)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            Text("Click a device to send these.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A tile that takes dropped files, highlighted while they hover.
private struct TileFrame<Content: View>: View {
    var isTargeted: Bool
    @ViewBuilder var content: Content

    var body: some View {
        CheeseCard(isHighlighted: isTargeted) {
            VStack(spacing: DesignTokens.Spacing.xSmall) {
                content
            }
            .frame(maxWidth: .infinity, minHeight: 104)
        }
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
    }
}

private struct PhoneTile: View {
    let model: SharePanelModel
    @State private var isTargeted = false

    var body: some View {
        TileFrame(isTargeted: isTargeted) {
            Image(systemName: "qrcode")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            Text("Phone")
                .font(DesignTokens.Typography.heading)
            Text("Scan a QR code, no app needed")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .onTapGesture { model.openPhone() }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.openPhone(adding: files.map(OutgoingItem.file))
            return true
        } isTargeted: { isTargeted = $0 }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Phone, scan a QR code")
    }
}

private struct DeviceTile: View {
    let model: SharePanelModel
    let peer: LocalSendPeer
    @State private var isTargeted = false

    var body: some View {
        TileFrame(isTargeted: isTargeted) {
            Image(systemName: peer.symbol)
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            Text(peer.alias)
                .font(DesignTokens.Typography.heading)
                .lineLimit(1)
            if let status = model.status(of: peer) {
                if case let .sending(fraction) = model.service.transfers[peer.id]?.state {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                }
                Text(status)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } else {
                Text(peer.deviceModel ?? "LocalSend")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                if model.isSending(to: peer) {
                    Button("Cancel", systemImage: "xmark.circle") { model.service.cancelTransfer(to: peer) }
                } else {
                    Button("Send Files…", systemImage: "doc") {
                        model.chooseFiles { items in model.service.send(items, to: peer) }
                    }
                    Button("Send Clipboard", systemImage: "doc.on.clipboard") { model.sendClipboard(to: peer) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(DesignTokens.Spacing.xSmall)
        }
        .onTapGesture { model.activate(peer) }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !model.isSending(to: peer) else { return false }
            model.service.send(files.map(OutgoingItem.file), to: peer)
            return true
        } isTargeted: { isTargeted = $0 }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Send to \(peer.alias)")
    }
}

private struct PhoneView: View {
    let model: SharePanelModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xxLarge) {
            VStack(spacing: DesignTokens.Spacing.small) {
                if let url = model.service.browserURL,
                   let code = QRGenerator.image(for: url.absoluteString, minimumPixels: Int(220 * displayScale)) {
                    Image(decorative: code, scale: displayScale)
                        .interpolation(.none)
                        .padding(DesignTokens.Spacing.large)
                        .background(.white, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
                    Text(url.absoluteString)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    CheeseEmptyState(symbol: "wifi.slash", title: "Not listening", detail: "Connect to Wi-Fi, then open Share again.")
                }
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                CheeseSectionHeader("Scan with your phone's camera", symbol: "camera")
                Text("The page lets your phone send photos, files and text to this Mac, and download what's below. The phone must be on the same Wi-Fi.")
                    .font(DesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CheeseSectionHeader(title: "On the page", symbol: "arrow.down.circle") {
                    Button("Add Files…") {
                        model.chooseFiles { items in model.service.offerToPhone(items) }
                    }
                    .controlSize(.small)
                }
                .padding(.top, DesignTokens.Spacing.small)
                if model.service.phoneItems.isEmpty {
                    Text("Nothing yet. Drop files on the Phone tile, or add them here.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: DesignTokens.Spacing.hairline) {
                            ForEach(model.service.phoneItems) { item in
                                CheeseListRow(symbol: item.symbol, title: item.name) {
                                    Button {
                                        model.service.withdrawFromPhone(item.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Stop offering this")
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Label("The link works until Cheese Share stops, 10 minutes after you close this panel.", systemImage: "clock")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignTokens.Spacing.xLarge)
    }
}
