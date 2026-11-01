import Testing
@testable import Cheese

struct TerminalTraceTests {
    @Test func recognizesCommonPrompts() {
        #expect(TerminalTraceParser.isPrompt("maanit@MacBook Cheese % make build"))
        #expect(TerminalTraceParser.isPrompt("bash-3.2$ ls"))
        #expect(TerminalTraceParser.isPrompt("$ npm test"))
        #expect(TerminalTraceParser.isPrompt("❯ swift build"))
        #expect(TerminalTraceParser.isPrompt("➜  Cheese git:(main) ✗ make"))
        #expect(TerminalTraceParser.isPrompt("maanit@MacBook ~ %"))
        #expect(TerminalTraceParser.isPrompt("❯"))
    }

    @Test func ignoresOutputThatMerelyContainsMarkers() {
        #expect(!TerminalTraceParser.isPrompt("Compiling 45 % done"))
        #expect(!TerminalTraceParser.isPrompt("Downloading 100%"))
        #expect(!TerminalTraceParser.isPrompt("echo $HOME is set"))
        #expect(!TerminalTraceParser.isPrompt("error: cannot find 'foo' in scope"))
        #expect(!TerminalTraceParser.isPrompt(""))
    }

    @Test func keepsOnlyTheLastCommandAndDropsTheWaitingPrompt() throws {
        let buffer = """
        maanit@mac Cheese % ls
        Makefile  README.md
        maanit@mac Cheese % make build
        Compiling Cheese
        Sources/App.swift:12:5: error: cannot find 'foo' in scope
        ** BUILD FAILED **
        maanit@mac Cheese %\u{20}\u{20}

        """
        let trace = try #require(TerminalTraceParser.extract(from: buffer))
        #expect(trace.command == "maanit@mac Cheese % make build")
        #expect(trace.output == [
            "Compiling Cheese",
            "Sources/App.swift:12:5: error: cannot find 'foo' in scope",
            "** BUILD FAILED **",
        ])
        #expect(trace.errorLines == [
            "Sources/App.swift:12:5: error: cannot find 'foo' in scope",
            "** BUILD FAILED **",
        ])
        #expect(trace.omittedLineCount == 0)
        #expect(trace.lineCount == 4)
    }

    @Test func aCommandWithNoOutputIncludesTheOneBefore() throws {
        let buffer = """
        ❯ python3 app.py
        Traceback (most recent call last):
        ZeroDivisionError: division by zero
        ❯ cd ..
        ❯
        """
        let trace = try #require(TerminalTraceParser.extract(from: buffer))
        #expect(trace.command == "❯ python3 app.py")
        #expect(trace.output.last == "❯ cd ..")
        #expect(trace.errorLines.first == "Traceback (most recent call last):")
    }

    @Test func withoutPromptsTakesTheLastLines() throws {
        let buffer = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let trace = try #require(TerminalTraceParser.extract(from: buffer, maxLines: 120))
        #expect(trace.command == nil)
        #expect(trace.output.count == 120)
        #expect(trace.output.first == "line 81")
        #expect(trace.output.last == "line 200")
        #expect(trace.omittedLineCount == 80)
    }

    @Test func longOutputKeepsTheCommandAndErrorsFromAnywhere() throws {
        let output = ["error: early failure"] + (1...300).map { "noise \($0)" }
        let buffer = (["$ make"] + output + ["$ "]).joined(separator: "\n")
        let trace = try #require(TerminalTraceParser.extract(from: buffer, maxLines: 50))
        #expect(trace.command == "$ make")
        #expect(trace.output.count == 49)
        #expect(trace.output.last == "noise 300")
        #expect(trace.omittedLineCount == 252)
        #expect(trace.errorLines == ["error: early failure"])

        let markdown = TerminalTraceParser.markdown(for: trace, appName: "Terminal", timestamp: "Nov 1, 2026")
        #expect(markdown.hasPrefix("### Terminal Trace (Terminal — Nov 1, 2026)\n```text\n$ make\n… 252 earlier lines omitted …\n"))
        #expect(markdown.contains("#### Errors\n```text\nerror: early failure\n```"))
    }

    @Test func shortOutputDoesNotRepeatErrors() throws {
        let trace = try #require(TerminalTraceParser.extract(from: "$ git push\nfatal: not a git repository\n$ "))
        let markdown = TerminalTraceParser.markdown(for: trace, appName: "iTerm2", timestamp: "now")
        #expect(markdown == "### Terminal Trace (iTerm2 — now)\n```text\n$ git push\nfatal: not a git repository\n```\n")
    }

    @Test func fenceOutgrowsBackticksInTheOutput() throws {
        let trace = try #require(TerminalTraceParser.extract(from: "$ cat README.md\n```swift\nlet x = 1\n```"))
        let markdown = TerminalTraceParser.markdown(for: trace, appName: "Ghostty", timestamp: "now")
        #expect(markdown.contains("\n````text\n"))
        #expect(markdown.hasSuffix("\n````\n"))
    }

    @Test func everythingKeepsTheWholeBufferUncut() throws {
        let lines = ["$ make"] + (1...300).map { "line \($0)" } + ["error: boom", "maanit@mac Cheese %"]
        let trace = try #require(TerminalTraceParser.extract(from: lines.joined(separator: "\n"), scope: .everything))
        #expect(trace.command == nil)
        #expect(trace.output.count == 302)
        #expect(trace.output.first == "$ make")
        #expect(trace.output.last == "error: boom")
        #expect(trace.omittedLineCount == 0)
        #expect(trace.errorLines.isEmpty)
    }

    @Test func everythingKeepsATypedLastCommand() throws {
        let trace = try #require(TerminalTraceParser.extract(from: "$ ls\nREADME.md\n$ make", scope: .everything))
        #expect(trace.output == ["$ ls", "README.md", "$ make"])
    }

    @Test func lastResponseScopeMatchesTheDefaultExtraction() {
        let buffer = "$ ls\nREADME.md\n$ git push\nfatal: no remote\n$ "
        #expect(TerminalTraceParser.extract(from: buffer, scope: .lastResponse) == TerminalTraceParser.extract(from: buffer))
    }

    @Test func stripsColorCodes() {
        #expect(TerminalTraceParser.stripANSI("\u{1B}[31merror:\u{1B}[0m bad") == "error: bad")
        #expect(TerminalTraceParser.extract(from: "  \n\n") == nil)
    }

    @Test func choosesTheFrontmostTerminalThenThePriorityOrder() {
        #expect(TerminalApp.choose(frontmost: "com.mitchellh.ghostty", running: ["com.apple.Terminal"]) == .ghostty)
        #expect(TerminalApp.choose(frontmost: "com.apple.Safari", running: ["com.microsoft.VSCode", "com.googlecode.iterm2"]) == .iTerm)
        #expect(TerminalApp.choose(frontmost: nil, running: ["com.apple.Safari"]) == nil)
    }
}
