import Foundation
import Synchronization

/// Runs a command-line tool with a time limit, stopping it when the limit passes or the job is
/// cancelled.
enum ProcessRunner {
    /// The running process's ID and whether it ended, shared with the watchdog and cancel handler.
    private final class Watch: Sendable {
        struct State {
            var pid: pid_t = 0
            var finished = false
            var timedOut = false
        }

        let state = Mutex(State())

        func stop(timedOut: Bool) {
            let pid = state.withLock { state -> pid_t in
                guard !state.finished, state.pid > 0 else { return 0 }
                state.timedOut = state.timedOut || timedOut
                return state.pid
            }
            if pid > 0 {
                kill(pid, SIGTERM)
            }
        }
    }

    /// Returns the exit status. Throws when the tool can't start or runs past `timeout`.
    static func run(_ executable: URL, arguments: [String], timeout: Duration, name: String) async throws -> Int32 {
        let watch = Watch()
        let watchdog = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            watch.stop(timedOut: true)
        }
        defer { watchdog.cancel() }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { finished in
                    watch.state.withLock { $0.finished = true }
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    watch.state.withLock { $0.pid = process.processIdentifier }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: FileToolError.message("\(name) couldn't be started: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            watch.stop(timedOut: false)
        }
        try Task.checkCancellation()
        if watch.state.withLock({ $0.timedOut }) {
            throw FileToolError.message("\(name) took too long, so it was stopped.")
        }
        return status
    }
}
