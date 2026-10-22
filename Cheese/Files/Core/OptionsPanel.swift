import AppKit
import SwiftUI

/// What the options panel can ask of its owner.
struct OptionsPanelActions {
    var run: @MainActor (JobWork) -> Void
    var close: @MainActor () -> Void
}

/// A compact floating panel for one tool: its input files (drag to reorder where order matters),
/// its options, and Run. Options are remembered per tool.
@MainActor
final class OptionsPanelController {
    private var panel: NSPanel?

    func show(_ tool: AnyFileTool, inputs: [URL], run: @escaping @MainActor (JobWork) -> Void) {
        close()
        let actions = OptionsPanelActions(
            run: { [weak self] work in
                self?.close()
                run(work)
            },
            close: { [weak self] in self?.close() }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.title = tool.id.title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentViewController = NSHostingController(rootView: tool.panel(inputs: inputs, actions: actions))
        panel.setContentSize(NSSize(width: 460, height: 520))
        if let screen = Screens.underMouse {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        self.panel = panel
        // The panel has text fields and may open file pickers, so Cheese becomes active while it's up.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct OptionsPanelView<Tool: FileTool>: View {
    let tool: Tool
    let store: ToolOptionsStore
    let actions: OptionsPanelActions
    @State private var inputs: [URL]
    @State private var options: Tool.Options

    init(tool: Tool, inputs: [URL], store: ToolOptionsStore, actions: OptionsPanelActions) {
        self.tool = tool
        self.store = store
        self.actions = actions
        _inputs = State(initialValue: inputs)
        _options = State(initialValue: store.load(Tool.Options.self, for: tool.id) ?? tool.defaultOptions)
    }

    private var problem: String? {
        let range = tool.id.fileCount
        if inputs.count < range.lowerBound {
            return range.lowerBound == 2 ? "Choose at least 2 files." : "Choose a file."
        }
        if inputs.count > range.upperBound {
            return "Choose just one file."
        }
        return tool.problem(with: options, inputs: inputs)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(Array(inputs.enumerated()), id: \.element) { index, url in
                        InputRow(url: url, canRemove: inputs.count > tool.id.fileCount.lowerBound) {
                            inputs.removeAll { $0 == url }
                        }
                        .modifier(ReorderableRow(index: index, isEnabled: tool.ordersInputs, inputs: $inputs))
                    }
                } header: {
                    Text(inputs.count == 1 ? "File" : "\(inputs.count) files")
                } footer: {
                    if tool.ordersInputs, inputs.count > 1 {
                        Text("Drag files to change their order.")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if Tool.Options.self != NoOptions.self {
                    Section("Options") {
                        tool.optionsView(options: $options, inputs: inputs)
                    }
                }
                if let hint = tool.hint {
                    Section {
                        Label(hint, systemImage: "info.circle")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            CheeseDivider()
            CheeseToolbar {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(DesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } trailing: {
                Button("Cancel", role: .cancel) { actions.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .controlSize(.regular)
            .padding(.vertical, DesignTokens.Spacing.xxSmall)
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func run() {
        guard problem == nil else { return }
        store.save(options, for: tool.id)
        actions.run(tool.work(inputs: inputs, options: options))
    }
}

private struct InputRow: View {
    let url: URL
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .frame(width: DesignTokens.Size.rowIcon, height: DesignTokens.Size.rowIcon)
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(FileSizeText.of(url))
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            if canRemove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove from this job")
            }
        }
    }
}

/// Drag a row onto another to move it there. The payload is a row index, never the file itself,
/// so dropping it in Finder can't copy anything.
private struct ReorderableRow: ViewModifier {
    let index: Int
    let isEnabled: Bool
    @Binding var inputs: [URL]
    private static let prefix = "cheese-input-row:"

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .draggable(Self.prefix + String(index))
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, item.hasPrefix(Self.prefix),
                          let from = Int(item.dropFirst(Self.prefix.count)), inputs.indices.contains(from), from != index
                    else { return false }
                    inputs.move(fromOffsets: [from], toOffset: from < index ? index + 1 : index)
                    return true
                }
        } else {
            content
        }
    }
}

/// "1.2 MB", for file rows and size hints.
enum FileSizeText {
    static func of(_ url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "" }
        return format(Int64(size))
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
