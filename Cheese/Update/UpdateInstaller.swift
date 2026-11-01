import CryptoKit
import Foundation
import Security
import os

/// Asks GitHub for the newest release.
protocol ReleaseFetching: Sendable {
    func latestRelease() async throws -> GitHubRelease
}

/// Downloads, checks and swaps in a new Cheese.app.
protocol UpdateInstalling: Sendable {
    /// Downloads the offer into a fresh staging folder, checks it, and returns the unpacked app.
    func stage(_ offer: UpdateOffer, replacing currentApp: URL) async throws -> StagedUpdate
    /// Starts the script that waits for Cheese to quit, swaps the app in and reopens it.
    func launchSwap(_ staged: StagedUpdate, replacing currentApp: URL) throws
}

/// A downloaded, verified Cheese.app waiting to be swapped in.
struct StagedUpdate: Sendable {
    var app: URL
    var folder: URL
}

enum UpdateError: LocalizedError, Equatable {
    case badResponse(status: Int)
    case rateLimited
    case downloadFailed
    case checksumMissing
    case checksumMismatch
    case bundleMissingInArchive
    case corruptedInfoPlist
    case bundleIdentifierMismatch(expected: String, found: String)
    case notNewer(found: String)
    case missingExecutable
    case signatureInvalid(status: Int32)
    case commandFailed(executable: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .badResponse(status):
            "GitHub answered with an error (HTTP \(status)). Check your internet connection and try again."
        case .rateLimited:
            "GitHub is limiting how often this network can check for updates. Try again in an hour."
        case .downloadFailed:
            "Cheese.zip couldn't be downloaded from GitHub."
        case .checksumMissing:
            "The release has no checksum file to check the download against."
        case .checksumMismatch:
            "The download didn't match the release's checksum, so it wasn't installed."
        case .bundleMissingInArchive:
            "The download didn't contain Cheese.app."
        case .corruptedInfoPlist:
            "The downloaded app has an unreadable Info.plist."
        case let .bundleIdentifierMismatch(expected, found):
            "The downloaded app isn't Cheese (expected \(expected), found \(found))."
        case let .notNewer(found):
            "The downloaded app is version \(found), which isn't newer than this one."
        case .missingExecutable:
            "The downloaded app is missing its program file."
        case let .signatureInvalid(status):
            "The downloaded app isn't signed by Cheese's author (code signing error \(status)), so it wasn't installed."
        case let .commandFailed(executable, code):
            "\((executable as NSString).lastPathComponent) failed with status \(code)."
        }
    }
}

/// `GET /repos/maanit-gupta/Cheese/releases/latest`.
struct GitHubReleaseFetcher: ReleaseFetching {
    var currentVersion: String

    func latestRelease() async throws -> GitHubRelease {
        guard let url = UpdatePlanner.latestReleaseURL else { throw UpdateError.badResponse(status: 0) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(UpdatePlanner.userAgent)/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let remaining = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-ratelimit-remaining")
            throw status == 403 || status == 429 || remaining == "0" ? UpdateError.rateLimited : UpdateError.badResponse(status: status)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

struct SystemUpdateInstaller: UpdateInstalling {
    /// The swap script appends what it did here, since it outlives Cheese and has nowhere else to say.
    static var logFile: URL {
        URL.libraryDirectory.appending(path: "Logs/Cheese/Update.log")
    }

    func stage(_ offer: UpdateOffer, replacing currentApp: URL) async throws -> StagedUpdate {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appending(path: UpdateSwapScript.stagingPrefix + UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let checksumText = try await String(decoding: download(offer.checksum, maxBytes: 4096), as: UTF8.self)
            guard let expected = UpdatePlanner.checksum(in: checksumText) else { throw UpdateError.checksumMissing }

            let archive = folder.appending(path: UpdatePlanner.archiveName)
            try await downloadFile(offer.archive, to: archive)
            guard try Self.sha256(of: archive) == expected else { throw UpdateError.checksumMismatch }

            let unpacked = folder.appending(path: "Unpacked", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
            // ditto keeps symlinks, extended attributes and the signature intact, as packaging does.
            try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            try? fileManager.removeItem(at: archive)

            let app = unpacked.appending(path: "Cheese.app", directoryHint: .isDirectory)
            try Self.validateBundle(at: app, currentApp: currentApp)
            _ = try? Self.run("/usr/bin/xattr", ["-cr", app.path])
            return StagedUpdate(app: app, folder: folder)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    func launchSwap(_ staged: StagedUpdate, replacing currentApp: URL) throws {
        let script = staged.folder.appending(path: "swap.sh")
        try UpdateSwapScript.text.write(to: script, atomically: true, encoding: .utf8)
        let log = Self.logFile
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)

        // `sh -c` with the paths as positional arguments, so none of them is ever parsed as shell text.
        // nohup and & detach the script from Cheese, which quits right after.
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [
            "-c", #"nohup /bin/sh "$0" "$@" >/dev/null 2>&1 &"#,
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            currentApp.path,
            staged.app.path,
            staged.folder.path,
            log.path,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(executable: "/bin/sh", code: process.terminationStatus)
        }
        Logger.update.notice("Swap script started for \(staged.app.path, privacy: .public)")
    }

    // MARK: - Checks

    /// The unpacked app must be Cheese, newer than this one, complete, and signed by the same team.
    static func validateBundle(at app: URL, currentApp: URL, currentBundleID: String? = Bundle.main.bundleIdentifier) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UpdateError.bundleMissingInArchive
        }
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              let executable = plist["CFBundleExecutable"] as? String,
              let version = plist["CFBundleShortVersionString"] as? String else {
            throw UpdateError.corruptedInfoPlist
        }
        let expectedID = currentBundleID ?? bundleID
        guard bundleID == expectedID else {
            throw UpdateError.bundleIdentifierMismatch(expected: expectedID, found: bundleID)
        }
        let currentVersion = Bundle(url: currentApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard UpdatePlanner.isVersion(version, newerThan: currentVersion) else {
            throw UpdateError.notNewer(found: version)
        }
        guard fileManager.isExecutableFile(atPath: app.appending(path: "Contents/MacOS/\(executable)").path) else {
            throw UpdateError.missingExecutable
        }
        let requirement = UpdatePlanner.signingRequirement(bundleIdentifier: expectedID, teamIdentifier: teamIdentifier(of: currentApp))
        try verifySignature(of: app, requirement: requirement)
    }

    /// What `codesign --verify --deep --strict -R=<requirement>` checks, through the Security framework.
    static func verifySignature(of app: URL, requirement text: String) throws {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw UpdateError.signatureInvalid(status: status) }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw UpdateError.signatureInvalid(status: status) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else { throw UpdateError.signatureInvalid(status: status) }
    }

    /// The team that signed the app at `url`; nil when it's ad-hoc signed or unsigned.
    static func teamIdentifier(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        // kSecCodeInfoTeamIdentifier, spelled out: the imported global isn't concurrency-safe.
        return info["teamid"] as? String
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue(UpdatePlanner.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func download(_ url: URL, maxBytes: Int) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(for: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count <= maxBytes else {
            throw UpdateError.checksumMissing
        }
        return data
    }

    private func downloadFile(_ url: URL, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(for: request(for: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateError.downloadFailed
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(executable: executable, code: process.terminationStatus)
        }
        return process.terminationStatus
    }
}
