import Foundation

/// Terminal Trace: copy the active terminal's last response, or everything in it, ready to paste.
@MainActor
final class TerminalTraceModule: CheeseModule {
    let id = ModuleID.terminalTrace
    private let service: TerminalTraceService

    init(askForAccessibility: @escaping @MainActor () -> Void) {
        service = TerminalTraceService(askForAccessibility: askForAccessibility)
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(
                id: .terminalTrace, title: "Terminal Trace", symbol: "terminal", module: id,
                paletteTitle: "Copy: Terminal Trace", menuTitle: "Copy Now", shortcut: .terminalTrace
            ) { [weak self] context in
                self?.service.copyTrace(previousApp: context.previousApp, scope: Preferences().terminalTraceScope)
            },
        ] + TerminalTraceScope.allCases.map { scope in
            // Picking a scope makes it the hotkey's choice and copies with it straight away.
            CheeseAction(
                id: .terminalTraceScope(scope), title: "Terminal Trace: \(scope.title)",
                symbol: scope.symbol, module: id,
                paletteTitle: "Copy: Terminal Trace (\(scope.title))", menuTitle: scope.title,
                isChecked: { Preferences().terminalTraceScope == scope }
            ) { [weak self] context in
                UserDefaults.standard.set(scope.rawValue, forKey: PreferenceKey.terminalTraceScope)
                self?.service.copyTrace(previousApp: context.previousApp, scope: scope)
            }
        }
    }

    // Nothing runs until the user asks for a trace.
    func start() {}
    func stop() {}
}
