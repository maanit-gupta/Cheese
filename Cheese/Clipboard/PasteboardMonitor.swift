import Foundation

/// Where a copy came from, for the terminal-aware parts of the clipboard. The app wiring supplies the
/// live version (frontmost app + Terminal Trace's Accessibility inspector); tests and the default use `.none`.
@MainActor
struct ClipSourceProbe {
    /// The frontmost app is a terminal host (standalone terminal or an editor with a terminal panel).
    var isTerminal: () -> Bool
    /// The text selected in that terminal, read through Accessibility.
    var terminalSelection: () -> String?

    static var none: ClipSourceProbe {
        ClipSourceProbe(isTerminal: { false }, terminalSelection: { nil })
    }
}

/// Polls the pasteboard's `changeCount` and hands each new clip to `onCapture`.
@MainActor
final class PasteboardMonitor {
    static let pollInterval = Duration.milliseconds(200)
    /// Electron/xterm.js and OSC 52 writes can bump `changeCount` before the data lands: one late look.
    static let settleDelay = Duration.milliseconds(60)

    private let pasteboard: any PasteboardReading
    private let source: ClipSourceProbe
    private let onCapture: (CapturedClip) -> Void
    private var lastChangeCount: Int
    private var ownChangeCount: Int?
    private var pollTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    init(
        pasteboard: any PasteboardReading,
        source: ClipSourceProbe = .none,
        onCapture: @escaping (CapturedClip) -> Void
    ) {
        self.pasteboard = pasteboard
        self.source = source
        self.onCapture = onCapture
        // Whatever is on the pasteboard at launch was already seen (or predates Cheese).
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self else { return }
                self.poll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        settleTask?.cancel()
        settleTask = nil
    }

    /// Cheese wrote this change itself (pasting from history); don't record it as a new copy.
    func ignoreChange(_ changeCount: Int) {
        ownChangeCount = changeCount
    }

    func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard changeCount != ownChangeCount else { return }
        settleTask?.cancel()
        settleTask = nil

        let fromTerminal = source.isTerminal()
        if capture(fromTerminal: fromTerminal) { return }
        guard !ClipClassifier.isPrivate(pasteboard.itemTypes) else { return }
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.settle(changeCount: changeCount, fromTerminal: fromTerminal)
        }
    }

    /// The single late re-read for a change that had nothing readable. A newer change is left to the
    /// next poll. Still empty after a terminal copy → the terminal's selection, read through Accessibility.
    func settle(changeCount: Int, fromTerminal: Bool) {
        settleTask = nil
        guard pasteboard.changeCount == changeCount, changeCount != ownChangeCount else { return }
        if capture(fromTerminal: fromTerminal) { return }
        guard fromTerminal,
              !ClipClassifier.isPrivate(pasteboard.itemTypes),
              let selection = source.terminalSelection(),
              selection.contains(where: { !$0.isWhitespace })
        else { return }
        let item = PasteboardItemContent(representations: [
            PasteboardRepresentation(type: PasteboardTypeID.plainText, data: Data(selection.utf8)),
        ])
        deliver(.text(plain: selection, items: [item], isRich: false), fromTerminal: true)
    }

    private func capture(fromTerminal: Bool) -> Bool {
        guard let clip = ClipReader.read(from: pasteboard) else { return false }
        deliver(clip, fromTerminal: fromTerminal)
        return true
    }

    /// Hands `clip` on, with a terminal-wrapped or prompt-prefixed link rebuilt into the plain link.
    private func deliver(_ clip: CapturedClip, fromTerminal: Bool) {
        onCapture(TerminalLinkNormalizer.linkClip(from: clip, fromTerminal: fromTerminal) ?? clip)
    }
}
