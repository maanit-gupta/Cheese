import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Cheese

private func url(_ name: String) -> URL {
    URL(filePath: "/tmp/\(name)")
}

struct ToolApplicabilityTests {
    @Test func classifiesByExtension() {
        #expect(FileKind(url: url("a.PDF")) == .pdf)
        #expect(FileKind(url: url("a.heic")) == .image)
        #expect(FileKind(url: url("a.webp")) == .image)
        #expect(FileKind(url: url("a.docx")) == .word)
        #expect(FileKind(url: url("a.xlsx")) == .excel)
        #expect(FileKind(url: url("a.xls")) == .excel)
        #expect(FileKind(url: url("a.csv")) == .excel)
        #expect(FileKind(url: url("a.pptx")) == .powerPoint)
        #expect(FileKind(url: url("a.md")) == .markdown)
        #expect(FileKind(url: url("a.html")) == .html)
        #expect(FileKind(url: url("a.txt")) == .plainText)
        #expect(FileKind(url: url("a.zip")) == .other)
        #expect(FileKind(url: URL(filePath: "/tmp/Folder", directoryHint: .isDirectory)) == .other)
    }

    @Test func onePDFGetsPDFToolsButNotMerge() {
        let tools = ToolApplicability.tools(for: [url("a.pdf")])
        #expect(!tools.contains(.mergePDFs))
        #expect(tools.contains(.splitPDF))
        #expect(tools.contains(.editPages))
        #expect(tools.contains(.compressPDF))
        #expect(tools.contains(.pdfToWord))
        #expect(!tools.contains(.convertImage))
    }

    @Test func twoPDFsCanMergeButNotOpenThePageEditor() {
        let tools = ToolApplicability.tools(for: [url("a.pdf"), url("b.pdf")])
        #expect(tools.contains(.mergePDFs))
        #expect(tools.contains(.watermarkPDF))
        #expect(!tools.contains(.editPages))
    }

    @Test func imagesGetImageToolsAndImagesToPDF() {
        let tools = ToolApplicability.tools(for: [url("a.jpg"), url("b.png")])
        #expect(tools == [.imagesToPDF, .convertImage, .resizeImage, .compressImage, .removeBackground])
    }

    @Test func officeAndTextFiles() {
        #expect(ToolApplicability.tools(for: [url("a.docx")]) == [.wordToPDF])
        #expect(ToolApplicability.tools(for: [url("a.csv")]) == [.excelToPDF])
        #expect(ToolApplicability.tools(for: [url("a.pptx")]) == [.powerPointToPDF])
        #expect(ToolApplicability.tools(for: [url("a.md")]) == [.webToPDF, .markdownToWord])
        #expect(ToolApplicability.tools(for: [url("a.txt")]) == [.webToPDF])
    }

    @Test func mixedSelectionsOnlyGetToolsThatTakeEveryFile() {
        #expect(ToolApplicability.tools(for: [url("a.pdf"), url("b.png")]).isEmpty)
        #expect(ToolApplicability.tools(for: [url("a.md"), url("b.txt")]) == [.webToPDF])
        #expect(ToolApplicability.tools(for: [url("a.md"), url("b.html")]) == [.webToPDF, .markdownToWord])
        #expect(ToolApplicability.tools(for: [URL]()).isEmpty)
        #expect(ToolApplicability.tools(for: [url("a.zip")]).isEmpty)
    }

    @Test func groupsKeepDisplayOrderAndSkipEmptyGroups() {
        let grouped = ToolApplicability.grouped([.convertImage, .imagesToPDF])
        #expect(grouped.map(\.group) == [.convert, .images])
        #expect(grouped.map(\.tools) == [[.imagesToPDF], [.convertImage]])
    }
}

struct OutputNamerTests {
    private let folder = URL(filePath: "/tmp/out", directoryHint: .isDirectory)

    @Test func suffixesAndConversions() {
        #expect(OutputNamer.fileName(base: "Report", suffix: "compressed", extension: "pdf") == "Report (compressed).pdf")
        #expect(OutputNamer.fileName(base: "Report", suffix: "pages 1-3", extension: "pdf") == "Report (pages 1-3).pdf")
        #expect(OutputNamer.fileName(base: "Report", suffix: nil, extension: "docx") == "Report.docx")
        let input = URL(filePath: "/tmp/in/Photo.heic")
        #expect(OutputNamer.output(for: input, suffix: nil, extension: "jpg", in: folder) { _ in false }.lastPathComponent == "Photo.jpg")
    }

    @Test func collisionsCountUpAndNeverOverwrite() {
        let taken: Set<String> = ["Report (compressed).pdf", "Report (compressed) 2.pdf"]
        let result = OutputNamer.uniqueFile(named: "Report (compressed).pdf", in: folder) { taken.contains($0.lastPathComponent) }
        #expect(result.lastPathComponent == "Report (compressed) 3.pdf")

        let folders: Set<String> = ["Report (images)"]
        let output = OutputNamer.uniqueFolder(named: "Report (images)", in: folder) { folders.contains($0.lastPathComponent) }
        #expect(output.lastPathComponent == "Report (images) 2")
    }

    @Test func dotsInTheBaseNameSurvive() {
        let input = URL(filePath: "/tmp/in/v1.2 notes.md")
        #expect(OutputNamer.output(for: input, suffix: nil, extension: "pdf", in: folder) { _ in false }.lastPathComponent == "v1.2 notes.pdf")
    }

    @Test func numberedFilesArePadded() {
        #expect(OutputNamer.numberedFile(base: "Report", index: 1, total: 10, extension: "png") == "Report-001.png")
        #expect(OutputNamer.numberedFile(base: "Report", index: 42, total: 1200, extension: "png") == "Report-0042.png")
    }
}

struct JobContextTests {
    @Test func reservesDistinctNamesAndFallsBackToDownloadsWhenNotWritable() throws {
        let folder = makeTemporaryDirectory()
        let downloads = makeTemporaryDirectory()
        let input = folder.appending(path: "Report.pdf")
        let context = JobContext(tool: .compressPDF, fallbackFolder: downloads, isWritable: { _ in true })
        let first = context.outputURL(for: input, suffix: "compressed", extension: "pdf")
        let second = context.outputURL(for: input, suffix: "compressed", extension: "pdf")
        #expect(first.lastPathComponent == "Report (compressed).pdf")
        #expect(second.lastPathComponent == "Report (compressed) 2.pdf")
        #expect(first.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)

        let readOnly = JobContext(tool: .compressPDF, fallbackFolder: downloads, isWritable: { _ in false })
        let fallback = readOnly.outputURL(for: input, suffix: "compressed", extension: "pdf")
        #expect(fallback.deletingLastPathComponent().standardizedFileURL == downloads.standardizedFileURL)
        try Data("x".utf8).write(to: fallback)
        #expect(readOnly.report(id: UUID(), inputs: [input], wasCancelled: false).wroteToDownloads)
    }

    @Test func failingAFileRemovesItsPartialOutput() throws {
        let folder = makeTemporaryDirectory()
        let input = folder.appending(path: "a.png")
        let context = JobContext(tool: .convertImage)
        let output = context.outputURL(for: input, suffix: nil, extension: "jpg")
        try Data("partial".utf8).write(to: output)
        context.fail(input, FileToolError.unreadable("a.png"))
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
        let report = context.report(id: UUID(), inputs: [input], wasCancelled: false)
        #expect(report.failures == [JobFailure(file: "a.png", reason: "a.png couldn't be opened.")])
        #expect(report.outputs.isEmpty)
    }
}

/// Collects what a queue reports.
private actor QueueRecorder {
    var reports: [JobReport] = []
    var maxRunning = 0

    func record(_ report: JobReport) {
        reports.append(report)
    }

    func observe(_ statuses: [JobQueue.Status]) {
        maxRunning = max(maxRunning, statuses.count { $0.isRunning })
    }
}

/// Polls until `condition` holds, failing after a few seconds.
private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct JobQueueTests {
    @Test func runsAtMostTwoJobsAtOnceAndFinishesThemAll() async throws {
        let recorder = QueueRecorder()
        let queue = JobQueue(onChange: { await recorder.observe($0) }, onFinish: { await recorder.record($0) })
        let released = Mutex(false)
        let folder = makeTemporaryDirectory()
        for index in 0..<3 {
            await queue.enqueue(JobWork(tool: .convertImage, inputs: [folder.appending(path: "\(index).png")]) { context in
                while !released.withLock({ $0 }) {
                    try await Task.sleep(for: .milliseconds(2))
                }
                context.fileFinished()
            })
        }
        try await waitUntil { await queue.statuses.count { $0.isRunning } == 2 }
        #expect(await queue.statuses.count == 3)
        released.withLock { $0 = true }
        try await waitUntil { await recorder.reports.count == 3 }
        #expect(await recorder.maxRunning == 2)
        #expect(await queue.statuses.isEmpty)
    }

    @Test func cancellingARunningJobDeletesItsOutputs() async throws {
        let recorder = QueueRecorder()
        let queue = JobQueue(onChange: { _ in }, onFinish: { await recorder.record($0) })
        let folder = makeTemporaryDirectory()
        let input = folder.appending(path: "Report.pdf")
        let written = Mutex<URL?>(nil)
        let id = await queue.enqueue(JobWork(tool: .splitPDF, inputs: [input]) { context in
            let output = context.outputURL(for: input, suffix: "pages 1-3", extension: "pdf")
            try Data("partial".utf8).write(to: output)
            written.withLock { $0 = output }
            while true {
                try await Task.sleep(for: .milliseconds(2))
            }
        })
        try await waitUntil { written.withLock { $0 != nil } }
        await queue.cancel(id)
        try await waitUntil { await recorder.reports.count == 1 }
        let report = try #require(await recorder.reports.first)
        #expect(report.wasCancelled)
        let output = try #require(written.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }

    @Test func aFailingFileDoesNotStopTheOthers() async throws {
        let recorder = QueueRecorder()
        let queue = JobQueue(onChange: { _ in }, onFinish: { await recorder.record($0) })
        let folder = makeTemporaryDirectory()
        let inputs = ["a", "b", "c"].map { folder.appending(path: "\($0).png") }
        await queue.enqueue(.perFile(tool: .convertImage, inputs: inputs) { input, context in
            guard input.lastPathComponent != "b.png" else { throw FileToolError.unreadable("b.png") }
            try Data("ok".utf8).write(to: context.outputURL(for: input, suffix: nil, extension: "jpg"))
        })
        try await waitUntil { await recorder.reports.count == 1 }
        let report = try #require(await recorder.reports.first)
        #expect(report.outputs.map(\.lastPathComponent) == ["a.jpg", "c.jpg"])
        #expect(report.failures.map(\.file) == ["b.png"])
        #expect(!report.wasCancelled)
    }
}

struct JobTextTests {
    @Test func titlesNameOneFileOrCountSeveral() {
        #expect(JobTitles.inProgress(.mergePDFs, inputs: [url("a.pdf"), url("b.pdf"), url("c.pdf")]) == "Merging 3 PDFs…")
        #expect(JobTitles.done(.convertImage, inputs: [url("Photo.heic")]) == "Converted Photo.heic")
        #expect(JobTitles.subject([url("a.png"), url("b.pdf")]) == "2 files")
    }

    @Test func indicatorSumsFilesAcrossJobs() {
        let a = JobQueue.Status(id: UUID(), tool: .mergePDFs, title: "", completed: 1, total: 4, isRunning: true)
        let b = JobQueue.Status(id: UUID(), tool: .convertImage, title: "", completed: 2, total: 6, isRunning: false)
        #expect(JobTitles.indicator([a, b]) == "3/10")
        #expect(JobTitles.indicator([]) == nil)
    }

    @Test func menuBarTextJoinsKeepAwakeAndFiles() {
        #expect(IndicatorSource.joined([.files: "3/10", .keepAwake: "∞"]) == "∞ · 3/10")
        #expect(IndicatorSource.joined([.files: "3/10"]) == "3/10")
        #expect(IndicatorSource.joined([:]) == nil)
    }

    private func report(outputs: [String] = [], failures: [JobFailure] = [], inputs: Int = 1, notes: [String] = [], downloads: Bool = false) -> JobReport {
        JobReport(
            id: UUID(), tool: .compressImage, inputs: (0..<inputs).map { url("\($0).jpg") },
            outputs: outputs.map(url), failures: failures, notes: notes, wroteToDownloads: downloads, wasCancelled: false
        )
    }

    @Test func summaryListsOutputsOrFailures() {
        #expect(JobSummary(report: report(outputs: ["0.jpg"])) == JobSummary(title: "Compressed 0.jpg", body: "0.jpg"))
        let partial = JobSummary(report: report(outputs: ["0.jpg"], failures: [JobFailure(file: "1.jpg", reason: "Broken.")], inputs: 2))
        #expect(partial.title == "Compressed 2 images")
        #expect(partial.body == "1.jpg: Broken.")
        let failed = JobSummary(report: report(failures: [JobFailure(file: "0.jpg", reason: "Broken.")]))
        #expect(failed.title == "Compress Images failed")
        let notes = JobSummary(report: report(outputs: ["0.jpg"], notes: ["4 MB → 1 MB"], downloads: true))
        #expect(notes.body.contains("4 MB → 1 MB"))
        #expect(notes.body.contains("Downloads"))
    }
}

struct ToolOptionsStoreTests {
    @Test func remembersOptionsPerTool() throws {
        let defaults = try #require(UserDefaults(suiteName: "ToolOptionsStoreTests-\(UUID())"))
        let store = ToolOptionsStore(defaults: defaults)
        #expect(store.load(ConvertImageTool.Options.self, for: .convertImage) == nil)
        store.save(ConvertImageTool.Options(format: .heic, quality: 0.5), for: .convertImage)
        #expect(store.load(ConvertImageTool.Options.self, for: .convertImage) == ConvertImageTool.Options(format: .heic, quality: 0.5))
        #expect(store.load(ConvertImageTool.Options.self, for: .resizeImage) == nil)
    }
}

/// Image files written for the image-tool tests.
enum FileFixtures {
    /// A `width`×`height` RGBA image: left half opaque red, right half transparent.
    static func halfTransparentImage(width: Int = 40, height: Int = 20) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return context.makeImage()
    }

    /// Writes `image` with an EXIF orientation tag and some GPS metadata.
    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType, orientation: Int = 1, gps: Bool = false) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 28.6, kCGImagePropertyGPSLatitudeRef: "N"]
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifLensModel: "Test Lens"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    static func properties(of url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }
}

/// Runs a tool's job synchronously and returns its report.
@MainActor
func runJob(_ work: JobWork) async throws -> JobReport {
    let id = UUID()
    let context = JobContext(tool: work.tool)
    try await work.run(context)
    return context.report(id: id, inputs: work.inputs, wasCancelled: false)
}

@MainActor
struct ConvertImageToolTests {
    @Test func pngToJPEGFlattensAlphaAndKeepsOrientation() async throws {
        let folder = makeTemporaryDirectory()
        let input = folder.appending(path: "Photo.png")
        let image = try #require(FileFixtures.halfTransparentImage())
        #expect(FileFixtures.write(image, to: input, type: .png, orientation: 6))

        let report = try await runJob(ConvertImageTool().work(inputs: [input], options: .init(format: .jpeg, quality: 0.9)))
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Photo.jpg")
        let properties = FileFixtures.properties(of: output)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 40)
        #expect(properties[kCGImagePropertyHasAlpha] as? Bool != true)
    }

    @Test func sameFormatGetsANumberedName() async throws {
        let folder = makeTemporaryDirectory()
        let input = folder.appending(path: "Photo.png")
        let image = try #require(FileFixtures.halfTransparentImage())
        FileFixtures.write(image, to: input, type: .png)
        let report = try await runJob(ConvertImageTool().work(inputs: [input], options: .init(format: .png)))
        #expect(report.outputs.map(\.lastPathComponent) == ["Photo 2.png"])
    }

    @Test func unreadableFilesAreReported() async throws {
        let folder = makeTemporaryDirectory()
        let input = folder.appending(path: "Broken.png")
        try Data("not an image".utf8).write(to: input)
        let report = try await runJob(ConvertImageTool().work(inputs: [input], options: .init()))
        #expect(report.outputs.isEmpty)
        #expect(report.failures.map(\.file) == ["Broken.png"])
    }

    @Test func webPIsOnlyOfferedWhenWritable() {
        let identifiers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        #expect(ImageFormat.writable.contains(.webp) == identifiers.contains(UTType.webP.identifier))
        #expect(ImageFormat.writable.contains(.png))
    }
}
