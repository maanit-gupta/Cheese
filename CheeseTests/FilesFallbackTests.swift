import Foundation
import PDFKit
import Testing
@testable import Cheese

struct FinderSelectionTests {
    @Test func parsesOnePathPerLine() {
        let urls = FinderSelection.paths(from: "/Users/me/a b.pdf\n/Users/me/Folder/\n")
        #expect(urls.map(\.lastPathComponent) == ["a b.pdf", "Folder"])
        #expect(urls.last?.hasDirectoryPath == true)
        #expect(FinderSelection.paths(from: "").isEmpty)
    }

    @Test func keepsOnlyFilesTheToolTakes() {
        let selection = [URL(filePath: "/tmp/a.pdf"), URL(filePath: "/tmp/notes.txt"), URL(filePath: "/tmp/b.pdf")]
        #expect(FinderSelection.usable(selection, for: .mergePDFs)?.map(\.lastPathComponent) == ["a.pdf", "b.pdf"])
        #expect(FinderSelection.usable([URL(filePath: "/tmp/a.pdf")], for: .mergePDFs) == nil)
        #expect(FinderSelection.usable([URL(filePath: "/tmp/x.png")], for: .compressPDF) == nil)
    }
}

struct NativeFallbackTests {
    private let office = URL(filePath: "/Applications/Microsoft Word.app")
    private let libre = URL(filePath: "/Applications/LibreOffice.app")

    @Test func prefersTheMatchingMicrosoftAppThenLibreOffice() {
        let both: (NativeOfficeApp) -> URL? = { [office, libre] app in app == .libreOffice ? libre : (app == .word ? office : nil) }
        #expect(NativeAppDetector.converter(for: .word, installed: both)?.app == .word)
        #expect(NativeAppDetector.converter(for: .excel, installed: both)?.app == .libreOffice)
        #expect(NativeAppDetector.converter(for: .powerPoint) { _ in nil } == nil)
    }

    @Test func appleScriptStringsAreEscaped() {
        #expect(MicrosoftOfficeBridge.quoted(#"/tmp/My "Q3" \ Report.docx"#) == #""/tmp/My \"Q3\" \\ Report.docx""#)
        let script = MicrosoftOfficeBridge.script(for: .word, input: URL(filePath: "/tmp/a\".docx"), output: URL(filePath: "/tmp/out.pdf"))
        #expect(script.contains(#"POSIX file "/tmp/a\".docx""#))
        #expect(script.contains("format PDF"))
        #expect(MicrosoftOfficeBridge.script(for: .powerPoint, input: URL(filePath: "/tmp/a.pptx"), output: URL(filePath: "/tmp/o.pdf")).contains("save as PDF"))
    }

    @Test func libreOfficeRunsHeadlessWithItsOwnProfile() {
        let arguments = LibreOfficeBridge.arguments(
            input: URL(filePath: "/tmp/Report.docx"), outputFolder: URL(filePath: "/tmp/out", directoryHint: .isDirectory),
            profile: URL(filePath: "/tmp/profile", directoryHint: .isDirectory)
        )
        #expect(arguments.first?.hasPrefix("-env:UserInstallation=file:///tmp/profile") == true)
        #expect(Array(arguments.dropFirst()) == ["--headless", "--norestore", "--convert-to", "pdf", "--outdir", "/tmp/out/", "/tmp/Report.docx"])
    }

    @Test func processesAreStoppedAtTheTimeLimit() async throws {
        #expect(try await ProcessRunner.run(URL(filePath: "/usr/bin/true"), arguments: [], timeout: .seconds(5), name: "true") == 0)
        await #expect(throws: FileToolError.message("sleep took too long, so it was stopped.")) {
            try await ProcessRunner.run(URL(filePath: "/bin/sleep"), arguments: ["10"], timeout: .milliseconds(200), name: "sleep")
        }
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.run(URL(filePath: "/nonexistent/tool"), arguments: [], timeout: .seconds(1), name: "tool")
        }
    }
}

@MainActor
@Suite(.enabled(if: Integration.isEnabled))
struct NativeFallbackIntegrationTests {
    @Test func aFailingNativeAppFallsBackToTheEmbeddedRenderer() async throws {
        let input = try FilesFixture.copy("report.docx")
        var tool = OfficeToPDFTool(kind: .word)
        tool.nativeOverride = NativeConverter(app: .libreOffice, location: URL(filePath: "/nonexistent/LibreOffice.app"))
        let report = try await runJob(tool.work(inputs: [input], options: NoOptions()))
        #expect(report.failures.isEmpty)
        #expect(report.outputs.map(\.lastPathComponent) == ["report.pdf"])
        #expect(report.notes == ["LibreOffice couldn't convert report.docx, so Cheese's built-in renderer was used."])
        #expect(TestPDFs.pageTexts(try #require(report.outputs.first)).first?.contains("Project Plan") == true)
    }
}
