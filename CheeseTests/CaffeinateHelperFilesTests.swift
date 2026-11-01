import Foundation
import Testing
@testable import Cheese

/// The root helper, run for real against stub `pmset`, `ioreg` and `ps` in a temporary folder,
/// so nothing changes on this Mac.
struct CaffeinateHelperFilesTests {
    private static let lidShut = #""AppleClamshellCausesSleep" = Yes "AppleClamshellState" = Yes"#
    private static let lidShutOnExternalDisplay = #""AppleClamshellCausesSleep" = No "AppleClamshellState" = Yes"#
    private static let lidOpen = #""AppleClamshellCausesSleep" = Yes "AppleClamshellState" = No"#
    private static let onPower = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t5%; charging; present: true\n"
    private static let cheese = "/Applications/Cheese.app/Contents/MacOS/Cheese"
    private var pid: Int32 { ProcessInfo.processInfo.processIdentifier }

    // MARK: - Running sessions

    @Test func disablesSleepWhileAskedAndRestoresItWhenWithdrawn() async throws {
        let box = try Sandbox(lid: Self.lidShut)
        try box.writeRequest("\(pid) 0 0")
        let helper = try box.start()
        try await box.waitFor { $0.contains("-a disablesleep 1") }
        #expect(box.isOwned)
        #expect(box.status == "active")
        #expect(helper.isRunning)

        try box.removeRequest()
        try await box.waitForExit(helper)
        // Turned off by hand: sleep comes back, but the Mac isn't put to sleep.
        #expect(box.commands == ["-a disablesleep 1", "-a disablesleep 0"])
        #expect(!box.isOwned)
        #expect(box.status == "off")
    }

    @Test func keepsGoingOnPowerWhateverTheCharge() async throws {
        let box = try Sandbox(lid: Self.lidShut, battery: Self.onPower)
        try box.writeRequest("\(pid) 0 10")
        let helper = try box.start()
        try await box.waitFor { $0.contains("-a disablesleep 1") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(helper.isRunning)
        try box.removeRequest()
        try await box.waitForExit(helper)
    }

    @Test func runningOutSleepsAShutMac() throws {
        let box = try Sandbox(lid: Self.lidShut, owned: true)
        try box.writeRequest("\(pid) 1 0")
        try box.runToEnd()
        #expect(box.commands == ["-a disablesleep 0", "sleepnow"])
        #expect(box.status == "expired")
    }

    @Test func runningOutLeavesAnOpenOrDockedMacAwake() throws {
        for lid in [Self.lidOpen, Self.lidShutOnExternalDisplay] {
            let box = try Sandbox(lid: lid, owned: true)
            try box.writeRequest("\(pid) 1 0")
            try box.runToEnd()
            #expect(box.commands == ["-a disablesleep 0"])
        }
    }

    @Test func theBatteryFloorEndsItAndSleepsAShutMac() throws {
        let battery = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t9%; discharging; 0:40 remaining present: true\n"
        let box = try Sandbox(lid: Self.lidShut, battery: battery, owned: true)
        try box.writeRequest("\(pid) 0 10")
        try box.runToEnd()
        #expect(box.commands == ["-a disablesleep 0", "sleepnow"])
        #expect(box.status == "battery")
    }

    // MARK: - Requests it refuses

    @Test func refusesAnythingButCheeseAskingInPlainNumbers() throws {
        let refused = ["abc", "\(pid) 0", "\(pid) 0 0 0", "\(pid) -1 0", "* * *", "99999999999999 0 0", "\(pid) 0 0; reboot"]
        for request in refused {
            let box = try Sandbox(lid: Self.lidShut, owned: true)
            try box.writeRequest(request)
            try box.runToEnd()
            // Restored, as at boot after a session a restart cut short; never slept.
            #expect(box.commands == ["-a disablesleep 0"], "request: \(request)")
        }
    }

    @Test func refusesOtherProcessesAndDeadOnes() throws {
        let other = try Sandbox(lid: Self.lidShut, owned: true, executable: "/usr/bin/caffeinate")
        try other.writeRequest("\(pid) 0 0")
        try other.runToEnd()
        #expect(other.commands == ["-a disablesleep 0"])

        let dead = try Sandbox(lid: Self.lidShut, owned: true)
        try dead.writeRequest("99999 0 0")
        try dead.runToEnd()
        #expect(dead.commands == ["-a disablesleep 0"])
    }

    @Test func refusesASymlinkedRequest() throws {
        let box = try Sandbox(lid: Self.lidShut, owned: true)
        let real = box.root.appendingPathComponent("elsewhere")
        try Data("\(pid) 0 0".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: box.request, withDestinationURL: real)
        try box.runToEnd()
        #expect(box.commands == ["-a disablesleep 0"])
    }

    @Test func leavesSleepAloneWhenItDidntChangeIt() throws {
        let box = try Sandbox(lid: Self.lidShut)
        try box.runToEnd()
        #expect(box.commands.isEmpty)
        #expect(box.status == nil)
    }

    // MARK: - Files

    @Test func scriptsAreValidShell() {
        #expect(shellSyntaxIsValid(CaffeinateHelperFiles.helperScript()))
        #expect(shellSyntaxIsValid(CaffeinateHelperFiles.installScript(uid: 501)))
        #expect(shellSyntaxIsValid(CaffeinateHelperFiles.uninstallScript))
    }

    @Test func launchDaemonRunsAtBootAndOnEveryRequest() throws {
        let data = Data(CaffeinateHelperFiles.launchDaemonPlist().utf8)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "com.maanitgupta.cheese.caffeinate")
        #expect(plist["ProgramArguments"] as? [String] == ["/bin/sh", "/Library/PrivilegedHelperTools/com.maanitgupta.cheese.caffeinate"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == false)
        #expect(plist["WatchPaths"] as? [String] == ["/Library/Application Support/Cheese/Caffeinate"])
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["com.maanitgupta.cheese"])
    }

    @Test func installWritesEverythingFromItsOwnTextAndLoadsTheJob() {
        let script = CaffeinateHelperFiles.installScript(uid: 501)
        #expect(script.contains("/usr/sbin/chown 501 '/Library/Application Support/Cheese/Caffeinate'"))
        #expect(script.contains("[ ! -L '/Library/Application Support/Cheese' ]"))
        #expect(script.contains(CaffeinateHelperFiles.versionLine))
        #expect(script.hasSuffix("/bin/launchctl bootstrap system '/Library/LaunchDaemons/com.maanitgupta.cheese.caffeinate.plist'"))
        // Nothing backgrounded from the privileged shell: macOS kills it when the prompt's script ends.
        #expect(!script.contains("nohup") && !script.contains("&)"))
        #expect(!script.contains(" cp "))
    }

    @Test func uninstallRestoresSleepOnlyIfTheHelperHadItOff() {
        let script = CaffeinateHelperFiles.uninstallScript
        #expect(script.contains("if [ -f '/Library/Application Support/Cheese/CaffeinateRoot/owned' ]; then /usr/bin/pmset -a disablesleep 0; fi"))
        #expect(script.hasPrefix("/bin/launchctl bootout system/com.maanitgupta.cheese.caffeinate"))
    }

    @Test func requestsAreThreePlainNumbers() {
        let deadline = Date(timeIntervalSince1970: 1_800_000_000.2)
        #expect(CaffeinateHelperFiles.request(pid: 42, deadline: deadline, batteryFloor: 10) == "42 1800000001 10\n")
        #expect(CaffeinateHelperFiles.request(pid: 42, deadline: nil, batteryFloor: 0) == "42 0 0\n")
        #expect(CaffeinateHelperFiles.request(pid: 42, deadline: nil, batteryFloor: 400) == "42 0 100\n")
        #expect(CaffeinateHelperFiles.expiredRequest(pid: 42, batteryFloor: 10) == "42 1 10\n")
    }

    @Test func knowsAnOlderHelper() {
        #expect(CaffeinateHelperFiles.isCurrent(installedScript: CaffeinateHelperFiles.helperScript()))
        #expect(!CaffeinateHelperFiles.isCurrent(installedScript: "#!/bin/sh\n# cheese-caffeinate-helper v0\n"))
    }

    @Test func quotingAndOutputParsing() {
        #expect(PrivilegedShell.shellQuoted("/tmp/it's here") == "'/tmp/it'\\''s here'")
        #expect(PrivilegedShell.appleScriptQuoted(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
        #expect(PrivilegedShell.isSleepDisabled(pmsetOutput: "System-wide power settings:\n SleepDisabled\t\t1\n"))
        #expect(!PrivilegedShell.isSleepDisabled(pmsetOutput: " SleepDisabled\t\t0\n"))
        #expect(PrivilegedShell.isUserCancelled(osascriptError: "execution error: User canceled. (-128)"))
    }

    private func shellSyntaxIsValid(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", script]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// A temporary folder holding the helper script, its request and state, and stub tools that log
/// what they're asked to do.
private struct Sandbox {
    let root: URL
    let request: URL
    let state: URL
    let log: URL
    let script: URL

    init(lid: String, battery: String = "", owned: Bool = false, executable: String = "/Applications/Cheese.app/Contents/MacOS/Cheese") throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory.appendingPathComponent("cheese-helper-\(UUID().uuidString)")
        let requests = root.appendingPathComponent("requests")
        state = root.appendingPathComponent("state")
        try fileManager.createDirectory(at: requests, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: state, withIntermediateDirectories: true)
        request = requests.appendingPathComponent("request")
        log = root.appendingPathComponent("log")
        try Data().write(to: log)

        let batteryFile = root.appendingPathComponent("battery")
        try Data(battery.utf8).write(to: batteryFile)
        let lidFile = root.appendingPathComponent("lid")
        try Data(lid.utf8).write(to: lidFile)
        let pmset = try Self.stub("pmset", in: root, body: """
            if [ "$1" = "-g" ]; then cat '\(batteryFile.path)'; exit 0; fi
            echo "$*" >> '\(log.path)'
            """)
        let ioreg = try Self.stub("ioreg", in: root, body: "cat '\(lidFile.path)'")
        let ps = try Self.stub("ps", in: root, body: "echo '\(executable)'")
        if owned {
            try Data().write(to: state.appendingPathComponent("owned"))
        }

        var environment = CaffeinateHelperFiles.Environment()
        environment.pmset = pmset
        environment.ioreg = ioreg
        environment.ps = ps
        environment.requestPath = request.path
        environment.stateFolder = state.path
        environment.interval = "0.05"
        script = root.appendingPathComponent("helper")
        try Data(CaffeinateHelperFiles.helperScript(environment).utf8).write(to: script)
    }

    private static func stub(_ name: String, in folder: URL, body: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func writeRequest(_ text: String) throws {
        try Data(text.utf8).write(to: request, options: .atomic)
    }

    func removeRequest() throws {
        try FileManager.default.removeItem(at: request)
    }

    var commands: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    var isOwned: Bool { FileManager.default.fileExists(atPath: state.appendingPathComponent("owned").path) }

    var status: String? {
        (try? String(contentsOf: state.appendingPathComponent("status"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Runs the helper when it should finish straight away.
    func runToEnd() throws {
        let process = try start()
        process.waitUntilExit()
    }

    func waitFor(_ condition: ([String]) -> Bool) async throws {
        for _ in 0..<300 {
            if condition(commands) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out; commands so far: \(commands)")
    }

    func waitForExit(_ process: Process) async throws {
        for _ in 0..<300 where process.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!process.isRunning)
    }
}
