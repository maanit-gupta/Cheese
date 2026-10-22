import AppKit
import SwiftUI

/// What the drop hub can reach. Wired in `App/`, so Files never talks to Share or the Shelf itself.
struct DropHubServices {
    var canShare: @MainActor () -> Bool = { false }
    var canShelve: @MainActor () -> Bool = { false }
    /// The Files tools that apply to these files and are switched on.
    var tools: @MainActor (_ files: [URL]) -> [ToolID] = { _ in [] }
    var share: @MainActor (DropPayload) -> Void = { _ in }
    var addToShelf: @MainActor (DropPayload) -> Void = { _ in }
    var openTool: @MainActor (ToolID, _ files: [URL]) -> Void = { _, _ in }
}

/// The drop hub's state: the dropped payload, its plan, and where each choice goes.
@MainActor
@Observable
final class DropHubModel {
    private(set) var payload: DropPayload?
    private(set) var plan: DropHubPlan?
    @ObservationIgnored let services: DropHubServices
    /// Closes the panel; set by its controller.
    @ObservationIgnored var onFinish: () -> Void = {}

    init(services: DropHubServices) {
        self.services = services
    }

    /// The plan for a payload, or nil when nothing can take it.
    func plan(for payload: DropPayload) -> DropHubPlan? {
        let plan = DropHubPlan.make(
            for: payload,
            canShare: services.canShare(),
            canShelve: services.canShelve(),
            tools: payload.fileURLs.isEmpty ? [] : services.tools(payload.fileURLs),
            size: Self.size(of:)
        )
        return plan.isEmpty ? nil : plan
    }

    /// Shows `payload`'s choices. False when there are none.
    @discardableResult
    func load(_ payload: DropPayload) -> Bool {
        guard let plan = plan(for: payload) else { return false }
        self.payload = payload
        self.plan = plan
        return true
    }

    /// Closes the hub, then hands the payload to the chosen feature.
    func perform(_ action: DropHubAction) {
        guard let payload else { return }
        let offered = plan.map { $0.primary.contains(action) || $0.sections.contains { $0.tools.contains { .tool($0) == action } } } ?? false
        guard offered else { return }
        finish()
        switch action {
        case .shareLink:
            services.share(payload)
        case .addToShelf:
            services.addToShelf(payload)
        case let .tool(tool):
            services.openTool(tool, payload.fileURLs)
        }
    }

    func finish() {
        payload = nil
        plan = nil
        onFinish()
    }

    private nonisolated static func size(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { return nil }
        return Int64(values?.fileSize ?? 0)
    }
}

/// The minimalist hub that opens under the menu bar icon when something is dropped on it: a summary
/// of the drop, Share Link / QR and Add to Shelf, then the Files tools that apply.
@MainActor
final class StatusItemDropPanelController {
    let model: DropHubModel
    private lazy var panel: CheesePanel = {
        let panel = CheesePanel(rootView: StatusItemDropPanelView(model: model))
        panel.onCancel = { [weak self] in self?.model.finish() }
        return panel
    }()

    init(services: DropHubServices) {
        model = DropHubModel(services: services)
        model.onFinish = { [weak self] in self?.panel.dismiss() }
    }

    /// Whether the icon should take this drag.
    func accepts(_ payload: DropPayload) -> Bool {
        model.plan(for: payload) != nil
    }

    /// Opens the hub under `anchor`, the menu bar icon's frame on screen.
    func show(_ payload: DropPayload, below anchor: NSRect) {
        guard model.load(payload) else { return }
        panel.present(at: .below(anchor))
    }
}

struct StatusItemDropPanelView: View {
    let model: DropHubModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            if let plan = model.plan, let payload = model.payload {
                SummaryPill(plan: plan, payload: payload) { model.finish() }
                if !plan.primary.isEmpty {
                    HStack(spacing: DesignTokens.Spacing.medium) {
                        ForEach(plan.primary, id: \.self) { action in
                            PrimaryCard(action: action) { model.perform(action) }
                        }
                    }
                }
                if !plan.sections.isEmpty {
                    CheeseDivider()
                    // Scrolls only when the tools don't fit.
                    ViewThatFits(in: .vertical) {
                        tools(plan.sections)
                        ScrollView { tools(plan.sections) }
                    }
                    .frame(maxHeight: 300)
                }
            }
        }
        .padding(DesignTokens.Spacing.panel)
        .frame(width: 340)
        .cheesePanelBackground()
    }
}

extension StatusItemDropPanelView {
    private func tools(_ sections: [DropHubPlan.ToolSection]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            ForEach(sections, id: \.group) { section in
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                    CheeseSectionCaps(section.group.title)
                    ForEach(section.tools, id: \.self) { tool in
                        Button { model.perform(.tool(tool)) } label: {
                            CheeseListRow(symbol: tool.symbol, title: "\(tool.title)…")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// The dropped thing in one line: icon or thumbnail, summary, close.
private struct SummaryPill: View {
    let plan: DropHubPlan
    let payload: DropPayload
    let close: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            thumbnail
                .frame(width: DesignTokens.Size.rowThumbnail, height: DesignTokens.Size.rowThumbnail)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            Text(plan.summary)
                .font(DesignTokens.Typography.secondary.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DesignTokens.Spacing.xxSmall)
            CheeseIconButton(symbol: "xmark", help: "Close", action: close)
        }
        .padding(.leading, DesignTokens.Spacing.xSmall)
        .padding(.trailing, DesignTokens.Spacing.xxSmall)
        .padding(.vertical, DesignTokens.Spacing.xxSmall)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    @ViewBuilder private var thumbnail: some View {
        switch payload {
        case let .image(png):
            if let image = NSImage(data: png) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                symbol
            }
        case let .files(urls) where urls.count == 1:
            Image(nsImage: NSWorkspace.shared.icon(forFile: urls[0].path(percentEncoded: false))).resizable().scaledToFit()
        default:
            symbol
        }
    }

    private var symbol: some View {
        Image(systemName: plan.symbol)
            .foregroundStyle(.secondary)
    }
}

/// Share Link / QR or Add to Shelf: a big, single-click card.
private struct PrimaryCard: View {
    let action: DropHubAction
    let perform: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: perform) {
            VStack(spacing: DesignTokens.Spacing.xSmall) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(height: 24)
                Text(title)
                    .font(DesignTokens.Typography.secondary.weight(.semibold))
                Text(detail)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.large)
            .background(
                isHovered ? AnyShapeStyle(Color.primary.opacity(DesignTokens.Opacity.hoverTint)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.animation(DesignTokens.Duration.quick, reduceMotion: DesignTokens.reducesMotion), value: isHovered)
    }

    private var symbol: String {
        action == .shareLink ? "square.and.arrow.up" : "tray.and.arrow.down"
    }

    private var title: String {
        action == .shareLink ? "Share Link / QR" : "Add to Shelf"
    }

    private var detail: String {
        action == .shareLink ? "Phone or nearby device" : "Keep it handy"
    }
}
