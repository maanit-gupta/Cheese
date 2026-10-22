import AppKit
import UniformTypeIdentifiers
import os

/// Local, offline file tools: PDF, conversion and image tools. Each is reachable from the
/// Finder extension, by dropping files on the menu bar icon, and from the command palette.
@MainActor
final class FilesModule: CheeseModule {
    let id = ModuleID.files
    let registry: FileToolRegistry
    private let panel = OptionsPanelController()
    private let notifications = JobNotifications()
    private let setIndicator: (String?) -> Void
    private var statuses: [JobQueue.Status] = []
    private(set) var isRunning = false
    private lazy var queue = JobQueue(
        onChange: { [weak self] statuses in await self?.update(statuses) },
        onFinish: { [weak self] report in await self?.finished(report) }
    )

    /// - Parameter setIndicator: shows or clears the `3/10` progress beside the menu bar icon.
    init(registry: FileToolRegistry = FileToolRegistry(), setIndicator: @escaping (String?) -> Void) {
        self.registry = registry
        self.setIndicator = setIndicator
    }

    var actions: [CheeseAction] {
        registry.toolIDs.map { tool in
            CheeseAction(id: .files(tool), title: "Files: \(tool.title)…", symbol: tool.symbol, module: id) { [weak self] context in
                self?.openFromPalette(tool, context: context)
            }
        }
    }

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
        panel.close()
        registry.closeWindows()
        Task { await queue.cancelAll() }
    }

    /// Opens the tool's options panel (or its own window) for these files.
    func open(_ tool: ToolID, files: [URL]) {
        guard isRunning else { return }
        let applicable = ToolApplicability.applies(tool, to: files)
        guard applicable else {
            Logger.files.info("\(tool.rawValue, privacy: .public) doesn't apply to the \(files.count) given file(s)")
            CheeseToast.show("\(tool.title) doesn't work with these files", systemImage: "exclamationmark.triangle.fill")
            return
        }
        if registry.openOwnWindow(tool, files: files, run: { [weak self] work in self?.run(work) }) {
            return
        }
        guard let anyTool = registry.tool(tool) else { return }
        panel.show(anyTool, inputs: files) { [weak self] work in
            self?.run(work)
        }
    }

    /// Opens the tool a Finder extension job asks for, after checking the files still exist.
    func openHandoff(_ url: URL) {
        guard let id = FilesHandoff.jobID(from: url) else { return }
        guard let container = FilesHandoff.container else {
            Logger.files.error("No App Group container for the Finder job")
            return
        }
        do {
            let job = try FilesHandoff.consume(id, from: container)
            let existing = job.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
            guard isRunning else {
                CheeseToast.show("Files is turned off in Settings", systemImage: "exclamationmark.triangle.fill")
                return
            }
            open(job.tool, files: existing)
        } catch {
            Logger.files.error("Couldn't read the Finder job: \(error.localizedDescription, privacy: .public)")
        }
    }

    func run(_ work: JobWork) {
        Task { await queue.enqueue(work) }
    }

    // MARK: Entry points

    /// The tools that apply to dropped files, grouped under PDF / Convert / Images. Nil when
    /// the module is off or nothing applies.
    func dropMenu(for files: [URL]) -> NSMenu? {
        guard isRunning else { return nil }
        let tools = ToolApplicability.tools(for: files).filter(registry.contains)
        guard !tools.isEmpty else { return nil }
        let menu = NSMenu()
        for (index, group) in ToolApplicability.grouped(tools).enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            menu.addItem(.sectionHeader(title: group.group.title))
            for tool in group.tools {
                let item = ClosureMenuItem(title: "\(tool.title)…") { [weak self] in
                    self?.open(tool, files: files)
                }
                item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        return menu
    }

    /// "Files: Merging 3 PDFs… — Cancel", one per job, for the top of the status menu.
    var progressMenuItems: [NSMenuItem] {
        statuses.map { status in
            let item = ClosureMenuItem(title: "Files: \(status.title) — Cancel") { [weak self] in
                Task { await self?.queue.cancel(status.id) }
            }
            item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            return item
        }
    }

    /// With Finder frontmost, the palette works on Finder's selection; otherwise, or when that
    /// selection doesn't suit the tool, it asks for files.
    private func openFromPalette(_ tool: ToolID, context: ActionContext) {
        if context.previousApp?.bundleIdentifier == FinderSelection.finderBundleID,
           let selection = FinderSelection.selectedFiles(),
           let files = FinderSelection.usable(selection, for: tool) {
            open(tool, files: files)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = tool.fileCount.upperBound > 1
        panel.canChooseDirectories = false
        panel.allowedContentTypes = tool.acceptedKinds.flatMap(\.contentTypes)
        panel.message = tool.title
        panel.prompt = "Choose"
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        open(tool, files: panel.urls)
    }

    // MARK: Queue callbacks

    private func update(_ statuses: [JobQueue.Status]) {
        self.statuses = statuses
        setIndicator(JobTitles.indicator(statuses))
    }

    private func finished(_ report: JobReport) {
        if report.wasCancelled {
            CheeseToast.show("Cancelled \(JobTitles.subject(report.inputs))", systemImage: "xmark.circle.fill")
            return
        }
        notifications.post(report)
    }
}

/// A menu item that runs a closure, for menus built on the fly.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor @Sendable () -> Void

    init(title: String, handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}
