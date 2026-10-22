import AppKit
import SwiftUI

/// The Spotlight-style command palette. It never activates Cheese, so the app the user was in stays
/// frontmost, and it closes before running anything.
@MainActor
final class PalettePanel {
    private let model = PaletteViewModel()
    private lazy var panel = makePanel()
    private var keyMonitor: Any?

    var isShown: Bool { panel.isVisible }

    /// Called with the chosen action once the palette has closed.
    init(run: @escaping (ActionID) -> Void) {
        model.onRun = { [weak self] id in
            self?.close()
            run(id)
        }
    }

    func show(entries: [PaletteEntry]) {
        model.reset(entries: entries)
        panel.present()
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        panel.dismiss()
    }

    private func makePanel() -> CheesePanel {
        let panel = CheesePanel(rootView: PaletteView(model: model))
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    // Arrows, Return and Esc are handled ahead of the search field, so they work while typing.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let isPanel = MainActor.assumeIsolated { event.window === self?.panel }
            guard isPanel else { return event }
            let handled = MainActor.assumeIsolated { self?.handleKey(keyCode) ?? false }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func handleKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 125: model.moveSelection(by: 1)
        case 126: model.moveSelection(by: -1)
        case 36, 76: model.runSelected()
        case 53: close()
        default: return false
        }
        return true
    }
}

private struct PaletteView: View {
    @Bindable var model: PaletteViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.medium) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                TextField("Search Cheese actions", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($searchFocused)
            }
            .padding(.horizontal, DesignTokens.Spacing.xLarge)
            .padding(.vertical, 14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: DesignTokens.Spacing.hairline) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                            CheeseListRow(symbol: entry.symbol, title: entry.title, detail: entry.moduleName, isSelected: index == model.selection) {
                                if let shortcut = entry.shortcut {
                                    Text(shortcut)
                                        .font(DesignTokens.Typography.keycap)
                                }
                            }
                            .id(entry.id)
                            .onTapGesture { model.run(entry.id) }
                        }
                    }
                    .padding(DesignTokens.Spacing.xSmall)
                }
                .onChange(of: model.selection) { _, _ in
                    if let id = model.selectedEntry?.id {
                        proxy.scrollTo(id)
                    }
                }
            }
            .overlay {
                if model.results.isEmpty {
                    CheeseEmptyState(symbol: "magnifyingglass", title: "No matching actions")
                }
            }
        }
        .frame(width: 600, height: 420)
        .cheesePanelBackground()
        .onAppear { searchFocused = true }
    }
}
