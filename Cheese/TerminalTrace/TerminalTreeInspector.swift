import AppKit
import ApplicationServices

/// An `AXUIElement` for `TerminalTreeWalker`, compared with `CFEqual` so cycles are caught.
struct LiveAXNode: TerminalAXNode {
    let element: AXUIElement

    static func == (lhs: LiveAXNode, rhs: LiveAXNode) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    func string(_ attribute: String) -> String? {
        copy(attribute) as? String
    }

    var domClasses: [String] {
        (copy("AXDOMClassList") as? [String]) ?? []
    }

    var children: [LiveAXNode] {
        ((copy(kAXChildrenAttribute) as? [AXUIElement]) ?? []).map(LiveAXNode.init)
    }

    var parent: LiveAXNode? {
        node(kAXParentAttribute)
    }

    func node(_ attribute: String) -> LiveAXNode? {
        guard let value = copy(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return LiveAXNode(element: unsafeDowncast(value, to: AXUIElement.self))
    }

    private func copy(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}

/// Reads a terminal host's focus, selection and text through Accessibility, for Terminal Trace and the
/// clipboard's terminal fallback. Needs `AXIsProcessTrusted()`; returns `.empty` without it.
@MainActor
struct TerminalTreeInspector {
    let pid: pid_t
    let kind: TerminalHostKind

    /// How long an Electron app takes to build its tree after `AXManualAccessibility` the first time.
    static let treeBuildDelay: Duration = .milliseconds(400)

    /// An inspector for the frontmost app if it's a registered terminal host.
    static func frontmost() -> TerminalTreeInspector? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let kind = TerminalHostRegistry.kind(of: app.bundleIdentifier) else { return nil }
        return TerminalTreeInspector(pid: app.processIdentifier, kind: kind)
    }

    /// One pass over the tree, without waiting.
    func snapshot() -> TerminalTreeSnapshot {
        guard AXIsProcessTrusted() else { return .empty }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        if kind == .integrated {
            // Electron (VS Code, Cursor, Windsurf) builds its tree only when asked; harmless elsewhere.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let root = LiveAXNode(element: app)
        return TerminalTreeWalker.snapshot(
            focused: root.node(kAXFocusedUIElementAttribute),
            window: root.node(kAXFocusedWindowAttribute),
            kind: kind
        )
    }

    /// Like `snapshot()`, but an editor that had no tree yet gets a moment to build one and a second look.
    func snapshotAllowingTreeBuild() async -> TerminalTreeSnapshot {
        let first = snapshot()
        guard kind == .integrated, first.text == nil, AXIsProcessTrusted() else { return first }
        try? await Task.sleep(for: Self.treeBuildDelay)
        return snapshot()
    }

    /// The text selected in the terminal, if any.
    func selectedText() -> String? {
        snapshot().selection
    }
}
