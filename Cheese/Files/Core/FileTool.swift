import Foundation
import SwiftUI

/// A Files tool: its options, the panel UI for them, and the job it runs.
/// Each tool is registered once and listed by Finder, the menu bar drop and the command palette.
@MainActor
protocol FileTool {
    associatedtype Options: Codable & Sendable & Equatable
    associatedtype OptionsBody: View

    var id: ToolID { get }
    var defaultOptions: Options { get }
    /// Whether the order of the inputs matters, so the panel lets the user drag them into order.
    var ordersInputs: Bool { get }
    /// A one-line note on the tool's known limits, shown in the panel.
    var hint: String? { get }

    @ViewBuilder
    func optionsView(options: Binding<Options>, inputs: [URL]) -> OptionsBody

    /// Why the options can't run on these inputs (like a bad page range), or nil when they can.
    func problem(with options: Options, inputs: [URL]) -> String?

    func work(inputs: [URL], options: Options) -> JobWork
}

extension FileTool {
    var ordersInputs: Bool { false }
    var hint: String? { nil }

    func problem(with options: Options, inputs: [URL]) -> String? { nil }
}

/// For tools with nothing to set.
struct NoOptions: Codable, Sendable, Equatable {}

/// A tool with its options type erased, so the registry can hold all of them.
@MainActor
struct AnyFileTool {
    let id: ToolID
    private let makePanel: ([URL], OptionsPanelActions) -> AnyView

    init<Tool: FileTool>(_ tool: Tool, store: ToolOptionsStore = ToolOptionsStore()) {
        id = tool.id
        makePanel = { inputs, actions in
            AnyView(OptionsPanelView(tool: tool, inputs: inputs, store: store, actions: actions))
        }
    }

    func panel(inputs: [URL], actions: OptionsPanelActions) -> AnyView {
        makePanel(inputs, actions)
    }
}

/// The last-used options per tool, as JSON in UserDefaults.
struct ToolOptionsStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load<Options: Decodable>(_ type: Options.Type, for tool: ToolID) -> Options? {
        guard let data = defaults.data(forKey: PreferenceKey.fileToolOptions(tool)) else { return nil }
        // Options from an older version that no longer decode fall back to the defaults.
        return try? JSONDecoder().decode(type, from: data)
    }

    func save(_ options: some Encodable, for tool: ToolID) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        defaults.set(data, forKey: PreferenceKey.fileToolOptions(tool))
    }
}
