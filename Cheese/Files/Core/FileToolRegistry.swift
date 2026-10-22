import Foundation

/// Every Files tool Cheese has, by ID. Most open the shared options panel; a few (the page
/// editor) open a window of their own.
@MainActor
final class FileToolRegistry {
    private let tools: [ToolID: AnyFileTool]
    private let windowTools: [ToolID: any WindowFileTool]

    init(tools: [AnyFileTool] = FileToolRegistry.standardTools, windowTools: [any WindowFileTool] = FileToolRegistry.standardWindowTools) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
        self.windowTools = Dictionary(uniqueKeysWithValues: windowTools.map { ($0.id, $0) })
    }

    static var standardTools: [AnyFileTool] {
        [
            AnyFileTool(MergeTool()),
            AnyFileTool(SplitTool()),
            AnyFileTool(CompressTool()),
            AnyFileTool(WatermarkTool()),
            AnyFileTool(PageNumbersTool()),
            AnyFileTool(ImagesToPDFTool()),
            AnyFileTool(PDFToImagesTool()),
            AnyFileTool(ConvertImageTool()),
            AnyFileTool(ResizeImageTool()),
            AnyFileTool(CompressImageTool()),
            AnyFileTool(RemoveBackgroundTool()),
        ]
    }

    static var standardWindowTools: [any WindowFileTool] {
        [PageEditorTool()]
    }

    /// Registered tools in display order.
    var toolIDs: [ToolID] {
        ToolID.allCases.filter(contains)
    }

    func contains(_ id: ToolID) -> Bool {
        tools[id] != nil || windowTools[id] != nil
    }

    func tool(_ id: ToolID) -> AnyFileTool? {
        tools[id]
    }

    /// Opens a tool that has its own window. Returns false for panel tools.
    func openOwnWindow(_ id: ToolID, files: [URL], run: @escaping @MainActor (JobWork) -> Void) -> Bool {
        guard let tool = windowTools[id] else { return false }
        tool.open(files, run: run)
        return true
    }

    func closeWindows() {
        for tool in windowTools.values {
            tool.close()
        }
    }
}

/// A tool with its own window instead of the options panel, like the page editor.
@MainActor
protocol WindowFileTool: AnyObject {
    var id: ToolID { get }
    func open(_ files: [URL], run: @escaping @MainActor (JobWork) -> Void)
    func close()
}
