import Testing
@testable import Cheese

/// An in-memory accessibility element.
private final class FakeNode: TerminalAXNode {
    var attributes: [String: String]
    var domClasses: [String]
    var children: [FakeNode] = []
    weak var parentNode: FakeNode?
    /// Extra links to simulate a misbehaving tree.
    var extraChildren: [FakeNode] = []

    init(_ role: String, _ attributes: [String: String] = [:], classes: [String] = [], _ children: [FakeNode] = []) {
        self.attributes = attributes.merging(["AXRole": role]) { current, _ in current }
        self.domClasses = classes
        self.children = children
        for child in children { child.parentNode = self }
    }

    func string(_ attribute: String) -> String? { attributes[attribute] }
    var parent: FakeNode? { parentNode }

    static func == (lhs: FakeNode, rhs: FakeNode) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

private func row(_ text: String) -> FakeNode {
    FakeNode("AXGroup", [:], [FakeNode("AXStaticText", ["AXValue": text])])
}

struct TerminalTreeTests {
    @Test func registryClassifiesHosts() {
        #expect(TerminalHostRegistry.kind(of: "com.apple.Terminal") == .standalone)
        #expect(TerminalHostRegistry.kind(of: "io.alacritty") == .standalone)
        #expect(TerminalHostRegistry.kind(of: "co.zeit.hyper") == .standalone)
        #expect(TerminalHostRegistry.kind(of: "com.microsoft.VSCodeInsiders") == .integrated)
        #expect(TerminalHostRegistry.kind(of: "com.exafunction.windsurf") == .integrated)
        #expect(TerminalHostRegistry.kind(of: "com.apple.Safari") == nil)
        #expect(!TerminalHostRegistry.isTerminalHost(nil))
        // Every Terminal Trace app is a registered host.
        for app in TerminalApp.allCases { #expect(TerminalHostRegistry.isTerminalHost(app.bundleID)) }
    }

    @Test func choosesAliasedAndIntegratedHosts() {
        #expect(TerminalApp.choose(frontmost: "io.alacritty", running: []) == .alacritty)
        #expect(TerminalApp.choose(frontmost: nil, running: ["io.alacritty", "com.microsoft.VSCode"]) == .alacritty)
        #expect(TerminalApp.choose(frontmost: "com.exafunction.windsurf", running: []) == .windsurf)
        #expect(TerminalApp.cursor.kind == .integrated)
        #expect(TerminalApp.iTerm.kind == .standalone)
    }

    @Test func nativeTerminalReadsTheFocusedTextArea() {
        let textArea = FakeNode("AXTextArea", ["AXValue": "$ ls\nfile.txt", "AXSelectedText": ""])
        let window = FakeNode("AXWindow", [:], [FakeNode("AXScrollArea", [:], [textArea])])
        let snapshot = TerminalTreeWalker.snapshot(focused: textArea, window: window, kind: .standalone)
        #expect(snapshot.buffer == "$ ls\nfile.txt")
        #expect(snapshot.selection == nil)
        #expect(snapshot.isTerminalFocused)
    }

    @Test func nativeTerminalPrefersTheSelection() {
        let textArea = FakeNode("AXTextArea", ["AXValue": "$ ls\nfile.txt", "AXSelectedText": "file.txt"])
        let snapshot = TerminalTreeWalker.snapshot(focused: textArea, window: nil, kind: .standalone)
        #expect(snapshot.text == "file.txt")
    }

    @Test func nativeTerminalFallsBackToTheLongestTextAreaInTheWindow() {
        let short = FakeNode("AXTextArea", ["AXValue": "short"])
        let long = FakeNode("AXTextArea", ["AXValue": "a much longer buffer"])
        let window = FakeNode("AXWindow", [:], [FakeNode("AXSplitGroup", [:], [short, long])])
        let snapshot = TerminalTreeWalker.snapshot(focused: nil as FakeNode?, window: window, kind: .standalone)
        #expect(snapshot.buffer == "a much longer buffer")
        #expect(!snapshot.isTerminalFocused)
    }

    @Test func vsCodeTerminalReadsXtermRowsAroundTheHelperTextArea() {
        let helper = FakeNode("AXTextArea", ["AXDescription": "Terminal input", "AXValue": ""], classes: ["xterm-helper-textarea"])
        let rows = FakeNode("AXList", [:], classes: ["xterm-accessibility-tree"], [row("$ npm test"), row("FAIL src/a.test.js")])
        let xterm = FakeNode("AXGroup", ["AXDescription": "Terminal 1, zsh"], classes: ["xterm"], [FakeNode("AXGroup", [:], [helper]), rows])
        let editor = FakeNode("AXTextArea", ["AXValue": "let x = 1"])
        let window = FakeNode("AXWindow", ["AXTitle": "app.ts — project"], [editor, xterm])
        let snapshot = TerminalTreeWalker.snapshot(focused: helper, window: window, kind: .integrated)
        #expect(snapshot.isTerminalFocused)
        #expect(snapshot.buffer == "$ npm test\nFAIL src/a.test.js")
    }

    @Test func vsCodeWithTheEditorFocusedNeverReturnsTheEditorText() {
        let editor = FakeNode("AXTextArea", ["AXValue": "let x = 1", "AXSelectedText": "x"])
        let tab = FakeNode("AXRadioButton", ["AXTitle": "Terminal"])
        let window = FakeNode("AXWindow", [:], [editor, tab])
        let snapshot = TerminalTreeWalker.snapshot(focused: editor, window: window, kind: .integrated)
        #expect(snapshot == .empty)

        // With the terminal panel open but unfocused, its text is still found.
        let xterm = FakeNode("AXGroup", ["AXDescription": "Terminal 1, zsh"], [row("$ make")])
        window.children.append(xterm)
        xterm.parentNode = window
        let withPanel = TerminalTreeWalker.snapshot(focused: editor, window: window, kind: .integrated)
        #expect(withPanel.buffer == "$ make")
        #expect(withPanel.selection == nil)
        #expect(!withPanel.isTerminalFocused)
    }

    @Test func walkingSurvivesCyclesAndStopsAtTheDepthLimit() {
        let a = FakeNode("AXGroup", ["AXDescription": "terminal"], [row("one")])
        let b = FakeNode("AXGroup", [:], [a])
        a.children.append(b) // cycle
        a.parentNode = b
        b.parentNode = a
        #expect(TerminalTreeWalker.rows(under: a) == "one")
        #expect(TerminalTreeWalker.terminalAncestor(of: b)?.text == "one")

        var deepest = FakeNode("AXStaticText", ["AXValue": "too deep"])
        for _ in 0..<(TerminalTreeWalker.maxDepth + 1) { deepest = FakeNode("AXGroup", [:], [deepest]) }
        #expect(TerminalTreeWalker.rows(under: deepest) == nil)
    }
}
