import Cocoa
import FinderSync
import os

/// Adds a "Cheese ▸" submenu to Finder's context menu with the Files tools that fit the selection.
/// It holds no tool logic: choosing a tool hands the job to Cheese through the App Group.
final class FinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "com.maanitgupta.cheese", category: "FinderExtension")

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(filePath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let submenu = NSMenu(title: "Cheese")
        if FilesHandoff.isEnabled {
            let files = FIFinderSyncController.default().selectedItemURLs() ?? []
            let groups = ToolApplicability.grouped(ToolApplicability.tools(for: files))
            guard !groups.isEmpty else { return nil }
            for (index, group) in groups.enumerated() {
                if index > 0 {
                    submenu.addItem(.separator())
                }
                for tool in group.tools {
                    let item = NSMenuItem(title: "\(tool.title)…", action: #selector(runTool(_:)), keyEquivalent: "")
                    item.target = self
                    // Finder copies the menu, so only the tag survives the round trip.
                    item.tag = ToolID.allCases.firstIndex(of: tool) ?? -1
                    item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
                    submenu.addItem(item)
                }
            }
        } else {
            let off = NSMenuItem(title: "Cheese Files is turned off", action: nil, keyEquivalent: "")
            off.isEnabled = false
            submenu.addItem(off)
        }
        let menu = NSMenu(title: "")
        let parent = NSMenuItem(title: "Cheese", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        parent.submenu = submenu
        menu.addItem(parent)
        return menu
    }

    @objc private func runTool(_ sender: NSMenuItem) {
        guard ToolID.allCases.indices.contains(sender.tag) else { return }
        let tool = ToolID.allCases[sender.tag]
        let files = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !files.isEmpty, let container = FilesHandoff.container else {
            logger.error("No selection or App Group container for \(tool.rawValue, privacy: .public)")
            return
        }
        do {
            let id = try FilesHandoff.write(FilesHandoff.Job(tool: tool, fileURLs: files), to: container)
            if let url = FilesHandoff.url(for: id) {
                NSWorkspace.shared.open(url)
            }
        } catch {
            logger.error("Couldn't hand off \(tool.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
