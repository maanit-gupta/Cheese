import Foundation
import os

/// The two shortcuts the user sets up in the Shortcuts app. macOS has no public way for an app to
/// switch Focus, but Shortcuts can, and Cheese runs them with the `shortcuts` tool.
enum HushShortcuts {
    static let on = "Cheese Hush On"
    static let off = "Cheese Hush Off"
    static let all = [on, off]
    static let tool = URL(filePath: "/usr/bin/shortcuts")

    /// The shortcut names missing from `shortcuts list` output.
    static func missing(fromList list: String) -> [String] {
        let names = Set(list.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return all.filter { !names.contains($0) }
    }

    /// Whether the On shortcut's output says a Focus was already on before it ran. Its last step
    /// outputs the Focus that was current, so anything but nothing means one was.
    static func focusWasAlreadyOn(output: String?) -> Bool {
        guard let output else { return false }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.lowercased() != "none" && text != "0"
    }
}

enum FocusSwitchResult: Equatable, Sendable {
    /// Focus is on. If it already was, Cheese leaves it on afterwards.
    case on(focusWasAlreadyOn: Bool)
    case failed(String)
}

/// Turns Focus on and off.
@MainActor
protocol FocusSwitching: AnyObject {
    func turnOn() async -> FocusSwitchResult
    func turnOff() async -> Bool
    /// Turns Focus off before returning, for quitting, waiting a few seconds at most.
    func turnOffNow()
    /// Shortcuts that aren't set up yet.
    func missingShortcuts() async -> [String]
}

/// Runs the user's Hush shortcuts through `/usr/bin/shortcuts`.
@MainActor
final class ShortcutsFocusSwitcher: FocusSwitching {
    func turnOn() async -> FocusSwitchResult {
        let output = FileManager.default.temporaryDirectory.appending(path: "CheeseHush-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            let status = try await ProcessRunner.run(
                HushShortcuts.tool,
                arguments: ["run", HushShortcuts.on, "--output-path", output.path(percentEncoded: false)],
                timeout: .seconds(10),
                name: "shortcuts"
            )
            guard status == 0 else {
                Logger.hush.error("\(HushShortcuts.on) exited with \(status)")
                return .failed("The “\(HushShortcuts.on)” shortcut didn't run. Check it in Settings → Hush.")
            }
            let text = try? String(contentsOf: output, encoding: .utf8)
            return .on(focusWasAlreadyOn: HushShortcuts.focusWasAlreadyOn(output: text))
        } catch {
            Logger.hush.error("Couldn't run \(HushShortcuts.on): \(error.localizedDescription)")
            return .failed("Couldn't run the “\(HushShortcuts.on)” shortcut.")
        }
    }

    func turnOff() async -> Bool {
        do {
            let status = try await ProcessRunner.run(
                HushShortcuts.tool, arguments: ["run", HushShortcuts.off], timeout: .seconds(10), name: "shortcuts"
            )
            return status == 0
        } catch {
            Logger.hush.error("Couldn't run \(HushShortcuts.off): \(error.localizedDescription)")
            return false
        }
    }

    func turnOffNow() {
        let process = Process()
        process.executableURL = HushShortcuts.tool
        process.arguments = ["run", HushShortcuts.off]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }
    }

    func missingShortcuts() async -> [String] {
        let list = await Task.detached { () -> String? in
            let process = Process()
            process.executableURL = HushShortcuts.tool
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        guard let list else { return HushShortcuts.all }
        return HushShortcuts.missing(fromList: list)
    }
}
