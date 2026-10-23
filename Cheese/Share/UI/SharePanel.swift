import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Share panel: a "Ready to Share" strip of staged items, the browser link as a QR code with
/// Copy Link and Stop, and nearby LocalSend devices that take the staged items with one click.
/// Opening it starts Cheese Share; closing it starts the 10-minute countdown to stopping.
@MainActor
final class SharePanelController {
    private let service: ShareService
    private let model: SharePanelModel
    private let openMenu: () -> Void
    private var panel: CheesePanel?

    /// - Parameters:
    ///   - clipboardItems: the current clipboard as things to send.
    ///   - openMenu: opens Cheese's menu bar menu, for the panel's back button.
    init(service: ShareService, clipboardItems: @escaping @MainActor () -> [OutgoingItem], openMenu: @escaping () -> Void = {}) {
        self.service = service
        self.openMenu = openMenu
        model = SharePanelModel(service: service, clipboardItems: clipboardItems)
        model.onClose = { [weak self] in self?.close() }
        model.onBackToMenu = { [weak self] in self?.backToMenu() }
    }

    var isShown: Bool { panel?.isVisible ?? false }

    /// Opens the panel, staging `items`.
    func show(ready items: [OutgoingItem] = []) {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.opened()
        model.service.stage(items)
        panel.present(at: .centered)
    }

    func close() {
        guard panel?.isVisible == true else { return }
        panel?.dismiss()
        service.panelClosed()
    }

    /// Closes the panel and opens the menu bar menu in its place. Sharing keeps running for the
    /// usual 10 minutes, so a phone mid-transfer isn't cut off.
    private func backToMenu() {
        close()
        // After the button's click finishes, or the menu's tracking loop swallows it.
        Task { @MainActor [openMenu] in openMenu() }
    }

    private func makePanel() -> CheesePanel {
        var behavior = CheesePanel.Behavior()
        // Stays open while files are dragged in from Finder.
        behavior.dismissesOnOutsideClick = false
        behavior.isMovable = true
        behavior.level = .floating
        let panel = CheesePanel(rootView: SharePanelView(model: model), behavior: behavior) { [model] content in
            let host = CheeseDropHostView(content: content, types: [.fileURL])
            host.onEntered = { [weak host] sender in
                guard !Self.files(in: sender).isEmpty else { return [] }
                model.dragMoved(to: host?.contentPoint(of: sender))
                return .copy
            }
            host.onUpdated = { [weak host] sender in model.dragMoved(to: host?.contentPoint(of: sender)) }
            host.onExited = { model.dragMoved(to: nil) }
            host.onDrop = { sender in model.drop(Self.files(in: sender)) }
            return host
        }
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    private static func files(in sender: any NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        // No folder sending.
        return (urls ?? []).filter { !$0.hasDirectoryPath }
    }
}

@MainActor
@Observable
final class SharePanelModel {
    enum Phase: Equatable {
        case starting
        case live(URL)
        /// Stopped from the panel; the link no longer works until sharing starts again.
        case stopped
        case unavailable(String)
    }

    let service: ShareService
    /// A drag of files is over the panel.
    private(set) var isDropTargeted = false
    /// The device a drag is over, which takes the files instead of the strip.
    private(set) var targetedPeer: LocalSendPeer.ID?
    private var stoppedByUser = false
    /// Device tiles' frames, top-left origin in the panel, for drops onto a device.
    @ObservationIgnored var tileFrames: [LocalSendPeer.ID: CGRect] = [:]
    @ObservationIgnored let clipboardItems: @MainActor () -> [OutgoingItem]
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onBackToMenu: () -> Void = {}
    /// Asks for files to share; an open panel, unless a test says otherwise.
    @ObservationIgnored var pickFiles: @MainActor () -> [URL] = SharePanelModel.openPanel
    @ObservationIgnored private var code: (link: String, scale: CGFloat, image: CGImage)?

    init(service: ShareService, clipboardItems: @escaping @MainActor () -> [OutgoingItem]) {
        self.service = service
        self.clipboardItems = clipboardItems
    }

    var phase: Phase {
        Self.phase(stoppedByUser: stoppedByUser, listening: service.listening, link: service.browserURL)
    }

    nonisolated static func phase(stoppedByUser: Bool, listening: ShareService.Listening, link: URL?) -> Phase {
        if stoppedByUser { return .stopped }
        switch listening {
        case .stopped, .starting: return .starting
        case .listening: return link.map(Phase.live) ?? .starting
        case let .unavailable(message): return .unavailable(message)
        }
    }

    /// `Report.pdf · 1.8 MB`, `3 items · 4.2 MB`, or a text's first line. Nil when nothing's staged.
    nonisolated static func summary(of items: [OutgoingItem]) -> String? {
        guard let first = items.first else { return nil }
        let bytes = items.reduce(Int64(0)) { total, item in
            if case .file = item.content { return total + item.size }
            return total
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        if items.count == 1 {
            if case .text = first.content { return "“\(first.name)”" }
            return "\(first.name) · \(size)"
        }
        return bytes > 0 ? "\(items.count) items · \(size)" : "\(items.count) items"
    }

    /// `IMG_2041.HEIC · 2.4 MB` or `3 files · 8 MB`. Nil when nothing's arrived.
    nonisolated static func receivedSummary(of received: [ShareService.ReceivedFile]) -> String? {
        guard let first = received.first else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: received.reduce(0) { $0 + $1.size }, countStyle: .file)
        return received.count == 1 ? "\(first.url.lastPathComponent) · \(size)" : "\(received.count) files · \(size)"
    }

    // MARK: Lifetime

    /// The panel opened: sharing starts (again) and the link goes live.
    func opened() {
        stoppedByUser = false
        service.panelOpened()
    }

    /// Stop: the link and every transfer end, and the strip empties.
    func stop() {
        stoppedByUser = true
        service.stop()
    }

    func startAgain() {
        opened()
    }

    // MARK: Staging

    func addFiles() {
        let files = pickFiles()
        service.stage(files.map(OutgoingItem.file))
    }

    /// Stages the clipboard. False when it's empty.
    @discardableResult
    func shareClipboard() -> Bool {
        let items = clipboardItems()
        guard !items.isEmpty else {
            CheeseToast.show("The clipboard is empty", systemImage: "clipboard")
            return false
        }
        service.stage(items)
        return true
    }

    // MARK: Dropping onto the panel

    func dragMoved(to point: CGPoint?) {
        isDropTargeted = point != nil
        targetedPeer = point.flatMap { point in tileFrames.first { $0.value.contains(point) }?.key }
    }

    /// Files dropped on a device go to it; anywhere else they're staged.
    func drop(_ files: [URL]) -> Bool {
        let peer = targetedPeer.flatMap { id in service.peers.first { $0.id == id } }
        dragMoved(to: nil)
        guard !files.isEmpty else { return false }
        let items = files.map(OutgoingItem.file)
        if let peer {
            guard !isSending(to: peer) else { return false }
            service.send(items, to: peer)
        } else {
            service.stage(items)
        }
        return true
    }

    // MARK: Devices

    /// Clicking a device sends what's staged, or asks for files when nothing is.
    func activate(_ peer: LocalSendPeer) {
        guard !isSending(to: peer) else { return }
        if service.staged.isEmpty {
            let files = pickFiles()
            if !files.isEmpty {
                service.send(files.map(OutgoingItem.file), to: peer)
            }
        } else {
            service.send(service.staged, to: peer)
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

    func status(of peer: LocalSendPeer) -> String? {
        switch service.transfers[peer.id]?.state {
        case nil: nil
        case .waiting: "Waiting…"
        case let .sending(fraction): "Sending \(Int(fraction * 100))%"
        case .done: "Sent ✓"
        case let .failed(message): message
        }
    }

    /// The link's QR code, made once per link and scale.
    func code(for link: URL, scale: CGFloat, side: CGFloat) -> CGImage? {
        if let code, code.link == link.absoluteString, code.scale == scale { return code.image }
        guard let image = QRGenerator.image(for: link.absoluteString, minimumPixels: Int(side * scale)) else { return nil }
        code = (link.absoluteString, scale, image)
        return image
    }

    private static func openPanel() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Share"
        NSApp.activate()
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}

struct SharePanelView: View {
    @Bindable var model: SharePanelModel

    var body: some View {
        VStack(spacing: 0) {
            header
            CheeseDivider()
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                ReadyStrip(model: model)
                if !model.service.received.isEmpty {
                    ReceivedStrip(service: model.service)
                }
                LinkSection(model: model)
                DevicesSection(model: model)
            }
            .padding(DesignTokens.Spacing.panel)
        }
        // Taller while the Received strip shows, so the devices keep their room.
        .frame(width: 380, height: model.service.received.isEmpty ? 460 : 510, alignment: .top)
        .overlay {
            if model.isDropTargeted, model.targetedPeer == nil {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.panel)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .cheesePanelBackground()
    }

    private var header: some View {
        CheeseToolbar {
            CheeseIconButton(symbol: "chevron.left", help: "Back to the Cheese menu") { model.onBackToMenu() }
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
        switch model.phase {
        case .starting: "Starting…"
        case .live: "Visible as \(Preferences().shareDeviceName)" + (model.service.isEncrypted ? " · encrypted" : " · unencrypted")
        case .stopped: "Stopped"
        case let .unavailable(message): message
        }
    }
}

/// Staged items, or a drop bar that invites some.
private struct ReadyStrip: View {
    let model: SharePanelModel

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            if let summary = SharePanelModel.summary(of: model.service.staged) {
                Image(systemName: "square.stack.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ready to Share")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .font(DesignTokens.Typography.secondary.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(model.service.staged.map(\.name).joined(separator: "\n"))
                Spacer(minLength: DesignTokens.Spacing.xxSmall)
                Button("Clear") { model.service.clearStaged() }
                    .buttonStyle(CheeseTextButtonStyle())
            } else {
                Image(systemName: "tray.and.arrow.down")
                    .foregroundStyle(.secondary)
                Text("Drop files here, click + to browse, or share the clipboard")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DesignTokens.Spacing.xxSmall)
                Button("Share Clipboard") { model.shareClipboard() }
                    .controlSize(.small)
            }
            CheeseIconButton(symbol: "plus", help: "Add files…") { model.addFiles() }
        }
        .padding(.leading, DesignTokens.Spacing.medium)
        .padding(.trailing, DesignTokens.Spacing.xSmall)
        .frame(minHeight: 40)
        .background {
            let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
            if model.service.staged.isEmpty {
                shape.strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.tertiary)
            } else {
                shape.fill(.quaternary.opacity(0.6))
            }
        }
    }
}

/// Files that came in from a phone or device: open one, or show them all in Finder.
private struct ReceivedStrip: View {
    let service: ShareService

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 0) {
                Text("Received from \(service.received.first?.from ?? "your phone")")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(SharePanelModel.receivedSummary(of: service.received) ?? "")
                    .font(DesignTokens.Typography.secondary.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(service.received.map { "\($0.url.lastPathComponent) — from \($0.from)" }.joined(separator: "\n"))
            Spacer(minLength: DesignTokens.Spacing.xxSmall)
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(service.received.map(\.url)) }
                .buttonStyle(CheeseTextButtonStyle())
            Menu {
                ForEach(service.received) { file in
                    Button(file.url.lastPathComponent, systemImage: "doc") { NSWorkspace.shared.open(file.url) }
                }
                Divider()
                Button("Show All in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(service.received.map(\.url))
                }
                Button("Clear List", systemImage: "xmark.circle") { service.clearReceived() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open a received file")
        }
        .padding(.leading, DesignTokens.Spacing.medium)
        .padding(.trailing, DesignTokens.Spacing.small)
        .frame(minHeight: 40)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }
}

/// The QR code and drop link, or why there isn't one.
private struct LinkSection: View {
    let model: SharePanelModel
    @Environment(\.displayScale) private var displayScale
    private let side: CGFloat = 140
    private let height: CGFloat = 250

    var body: some View {
        switch model.phase {
        case let .live(link):
            if let code = model.code(for: link, scale: displayScale, side: side) {
                ShareLinkCard(code: code, side: side, link: link, expiresAt: model.service.linkExpiresAt) { model.stop() }
            }
        case .starting:
            placeholder { ProgressView().controlSize(.small) }
        case .stopped:
            placeholder {
                CheeseEmptyState(symbol: "stop.circle", title: "Sharing stopped", detail: "The link no longer works.") {
                    Button("Share Again") { model.startAgain() }
                        .controlSize(.small)
                }
            }
        case let .unavailable(message):
            placeholder { CheeseEmptyState(symbol: "wifi.slash", title: "Can't share right now", detail: message) }
        }
    }

    private func placeholder(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }
}

private struct DevicesSection: View {
    let model: SharePanelModel
    private let columns = [GridItem(.flexible(), spacing: DesignTokens.Spacing.small), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
            CheeseSectionCaps("Nearby devices")
            if model.service.peers.isEmpty {
                Label(emptyLine, systemImage: model.service.discoveryProblem == nil ? "dot.radiowaves.left.and.right" : "wifi.exclamationmark")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(model.service.discoveryProblem == nil ? Color.secondary : Color.orange)
                    .padding(.horizontal, DesignTokens.Spacing.medium)
            } else {
                // Scrolls only when the devices don't fit.
                ViewThatFits(in: .vertical) {
                    grid
                    ScrollView { grid }
                }
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.small) {
            ForEach(model.service.peers) { peer in
                DeviceTile(model: model, peer: peer)
            }
        }
    }

    private var emptyLine: String {
        model.service.discoveryProblem ?? "Looking for devices running LocalSend…"
    }
}

/// A nearby LocalSend device: click to send what's staged, or drop files on it.
private struct DeviceTile: View {
    let model: SharePanelModel
    let peer: LocalSendPeer
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: peer.symbol)
                .foregroundStyle(.tint)
                .frame(width: DesignTokens.Size.rowIcon)
            VStack(alignment: .leading, spacing: 0) {
                Text(peer.alias)
                    .font(DesignTokens.Typography.secondary.weight(.medium))
                    .lineLimit(1)
                Text(model.status(of: peer) ?? peer.deviceModel ?? "LocalSend")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                if model.isSending(to: peer) {
                    Button("Cancel", systemImage: "xmark.circle") { model.service.cancelTransfer(to: peer) }
                } else {
                    Button("Send Files…", systemImage: "doc") {
                        let files = model.pickFiles()
                        if !files.isEmpty { model.service.send(files.map(OutgoingItem.file), to: peer) }
                    }
                    Button("Send Clipboard", systemImage: "doc.on.clipboard") { model.sendClipboard(to: peer) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, DesignTokens.Spacing.small)
        .frame(height: 40)
        .background(background, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row))
        .overlay(alignment: .bottom) {
            if case let .sending(fraction) = model.service.transfers[peer.id]?.state {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * fraction, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, DesignTokens.Spacing.small)
            }
        }
        .overlay {
            if model.targetedPeer == peer.id {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row).strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.row))
        .onTapGesture { model.activate(peer) }
        .onHover { isHovered = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.tileFrames[peer.id] = $0 }
        .onDisappear { model.tileFrames[peer.id] = nil }
        .help(model.service.staged.isEmpty ? "Click to choose files for \(peer.alias)" : "Click to send what's ready to \(peer.alias)")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Send to \(peer.alias)")
    }

    private var background: AnyShapeStyle {
        if model.targetedPeer == peer.id { return AnyShapeStyle(Color.accentColor.opacity(DesignTokens.Opacity.activeTint)) }
        return isHovered ? AnyShapeStyle(Color.primary.opacity(DesignTokens.Opacity.hoverTint)) : AnyShapeStyle(.quaternary.opacity(0.6))
    }
}
