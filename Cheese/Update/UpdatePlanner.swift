import Foundation

/// A release version like `v2.4` or `2.3.1`. Missing parts count as zero, so `2.3` and `2.3.0` are
/// the same version; a pre-release or build suffix (`-beta`, `+5`) is ignored.
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let components: [Int]

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        let core = text.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        components = numbers
    }

    /// `2.4` or `2.3.1`, without the `v`.
    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in lhs.padded(to: rhs) where left != right {
            return left < right
        }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.padded(to: rhs).allSatisfy { $0 == $1 }
    }

    private func padded(to other: Self) -> [(Int, Int)] {
        let count = max(components.count, other.components.count)
        return (0..<count).map { index in
            (index < components.count ? components[index] : 0,
             index < other.components.count ? other.components[index] : 0)
        }
    }
}

/// The parts of GitHub's "latest release" answer the updater reads.
struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: String
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body
        case htmlURL = "html_url"
        case draft, prerelease, assets
    }
}

/// A newer release Cheese can install.
struct UpdateOffer: Equatable, Sendable {
    /// `2.4`, without the `v`.
    var version: String
    var notes: String
    var releasePage: URL?
    var archive: URL
    /// `Cheese.zip.sha256`, the same file install.sh checks.
    var checksum: URL
}

/// What the user chose in the update prompt.
enum UpdatePromptChoice: Sendable {
    case install
    case later
    case skip
}

/// Why Cheese can't replace itself where it is.
enum InstallLocationProblem: Equatable, Sendable {
    /// Opened straight from a download: macOS runs it from a randomized read-only copy.
    case translocated
    /// On a disk image or another read-only volume.
    case readOnlyVolume
    /// The folder (or the app) belongs to someone else, as /Applications does for a standard user.
    case notWritable(folder: String)

    var title: String {
        switch self {
        case .translocated, .readOnlyVolume: "Move Cheese to Applications"
        case .notWritable: "Cheese can't replace itself"
        }
    }

    var message: String {
        switch self {
        case .translocated:
            "Cheese is running from a temporary copy macOS made when it was opened from Downloads. Move Cheese.app into your Applications folder, open it from there, and update again."
        case .readOnlyVolume:
            "Cheese is running from a disk image or another read-only volume. Move Cheese.app into your Applications folder, open it from there, and update again."
        case let .notWritable(folder):
            "Your account can't change \(folder). Download the update yourself, or run the install command from the README, which asks for an administrator password."
        }
    }
}

/// What a launch should say about the last update.
enum UpdateLaunchResult: Equatable, Sendable {
    case installed(version: String)
    case failed(version: String)
}

/// The updater's decisions, with nothing touching the network, the disk or AppKit.
enum UpdatePlanner {
    static let repository = "maanit-gupta/Cheese"
    static let archiveName = "Cheese.zip"
    static let checksumName = "Cheese.zip.sha256"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")
    /// GitHub turns away API requests without one.
    static let userAgent = "Cheese-macOS-Updater"
    static let checkInterval: TimeInterval = 12 * 60 * 60
    static let notesLimit = 600

    /// The release as an offer, when it's a published, newer version than `currentVersion`.
    static func offer(from release: GitHubRelease, currentVersion: String) -> UpdateOffer? {
        guard !release.draft, !release.prerelease,
              let remote = AppVersion(release.tagName),
              let local = AppVersion(currentVersion), remote > local else { return nil }
        let tag = release.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        func asset(_ name: String) -> URL? {
            release.assets.first { $0.name == name }.flatMap { URL(string: $0.browserDownloadURL) }
                ?? URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(name)")
        }
        guard let archive = asset(archiveName), let checksum = asset(checksumName),
              archive.scheme == "https", checksum.scheme == "https" else { return nil }
        return UpdateOffer(
            version: remote.description,
            notes: plainNotes(release.body ?? ""),
            releasePage: URL(string: release.htmlURL),
            archive: archive,
            checksum: checksum
        )
    }

    static func isVersion(_ remote: String, newerThan local: String) -> Bool {
        guard let remote = AppVersion(remote), let local = AppVersion(local) else { return false }
        return remote > local
    }

    /// Whether a found update should be put in front of the user: always when they asked, otherwise
    /// unless they skipped this version or were already told about it this launch.
    static func shouldAnnounce(_ offer: UpdateOffer, skippedVersion: String?, announcedVersion: String?, userInitiated: Bool) -> Bool {
        if userInitiated { return true }
        return offer.version != skippedVersion && offer.version != announcedVersion
    }

    /// Whether an automatic check is due, `interval` after the last one.
    static func isCheckDue(lastCheck: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        // A clock set back counts as due rather than waiting out the difference.
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }

    /// Release notes for an alert: GitHub Markdown reduced to plain lines, about `limit` characters
    /// long, cut at a line break.
    static func plainNotes(_ markdown: String, limit: Int = notesLimit) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("**Full Changelog**") || line.hasPrefix("<!--") { return nil }
            while line.hasPrefix("#") { line.removeFirst() }
            if line.hasPrefix("* ") || line.hasPrefix("- ") { line = "• " + line.dropFirst(2) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            return line.trimmingCharacters(in: .whitespaces)
        }
        // Collapse runs of blank lines and trim the ends.
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) {
            kept.append(line)
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
        let text = kept.joined(separator: "\n")
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let atLine = cut.lastIndex(of: "\n").map { cut[..<$0] } ?? cut
        return atLine.trimmingCharacters(in: .whitespacesAndNewlines) + "\n…"
    }

    /// The hex digest in a `shasum -a 256` file naming `fileName` (or naming nothing), lowercased.
    static func checksum(in text: String, for fileName: String = archiveName) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let digest = fields.first, digest.count == 64, digest.allSatisfy(\.isHexDigit) else { continue }
            let name = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
            // `shasum -b` marks binary files with a leading `*`.
            if name.isEmpty || name == fileName || name == "*" + fileName {
                return digest.lowercased()
            }
        }
        return nil
    }

    /// Whether Cheese can swap itself out from where it runs.
    static func installLocationProblem(
        bundlePath: String, isOnReadOnlyVolume: Bool, isFolderWritable: Bool, isBundleWritable: Bool
    ) -> InstallLocationProblem? {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if isOnReadOnlyVolume { return .readOnlyVolume }
        guard isFolderWritable, isBundleWritable else {
            let folder = (bundlePath as NSString).deletingLastPathComponent
            return .notWritable(folder: folder.isEmpty ? "/" : folder)
        }
        return nil
    }

    /// The code requirement a downloaded Cheese must meet: Cheese's bundle identifier, and when the
    /// running copy carries a team, a certificate from Apple issued to that same team. That's the
    /// author's Apple Development identity for every published build, so an archive signed by
    /// anyone else is refused.
    static func signingRequirement(bundleIdentifier: String, teamIdentifier: String?) -> String {
        let identifier = "identifier \"\(quoted(bundleIdentifier))\""
        guard let team = teamIdentifier, !team.isEmpty else { return identifier }
        return "anchor apple generic and \(identifier) and certificate leaf[subject.OU] = \"\(quoted(team))\""
    }

    /// What this launch should report, given the update Cheese last handed to the swap script.
    static func launchResult(currentVersion: String, pendingVersion: String?) -> UpdateLaunchResult? {
        guard let pendingVersion, let pending = AppVersion(pendingVersion) else { return nil }
        guard let current = AppVersion(currentVersion), current >= pending else { return .failed(version: pendingVersion) }
        return .installed(version: pendingVersion)
    }

    /// True when this launch runs a different version from the last one, so permissions tied to the
    /// old binary may need tidying. Never on the first launch.
    static func isFirstLaunchAfterUpgrade(previousVersion: String?, currentVersion: String) -> Bool {
        guard let previousVersion else { return false }
        return previousVersion != currentVersion
    }

    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// The detached script that swaps the new Cheese.app in once this one has quit. Paths are passed as
/// arguments, never written into the script, so no name can break out of its quoting.
///
///     sh swap.sh <pid> <target .app> <new .app> <staging folder> <log file> [opener]
enum UpdateSwapScript {
    /// Kept beside the old app until the new one is in place, then removed.
    static let backupSuffix = ".backup"
    /// The staging folder's name starts with this; the script refuses to delete any other folder.
    static let stagingPrefix = "CheeseUpdate-"

    static let text = #"""
    #!/bin/sh
    # cheese-update-swap v1: waits for Cheese to quit, swaps the new Cheese.app in, reopens it.
    pid="$1"; target="$2"; new="$3"; staging="$4"; log="$5"; opener="${6:-/usr/bin/open}"
    backup="$target.backup"

    say() { printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log" 2>/dev/null; }
    tidy() { case "$staging" in */CheeseUpdate-*) /bin/rm -rf "$staging" ;; esac; }

    case "$pid" in ''|*[!0-9]*) say "refused: bad pid"; exit 2 ;; esac
    case "$target" in *.app) ;; *) say "refused: target isn't an app"; exit 2 ;; esac
    case "$new" in *.app) ;; *) say "refused: new copy isn't an app"; exit 2 ;; esac

    # Up to 15 s for Cheese to quit on its own.
    count=0
    while kill -0 "$pid" 2>/dev/null; do
        count=$((count + 1))
        if [ "$count" -ge 75 ]; then
            say "Cheese ($pid) didn't quit; stopping it"
            kill -9 "$pid" 2>/dev/null
            sleep 0.5
            break
        fi
        sleep 0.2
    done

    if [ ! -d "$new" ]; then
        say "failed: the new copy is missing"
        tidy
        "$opener" "$target"
        exit 1
    fi

    /bin/rm -rf "$backup"
    if [ -e "$target" ] && ! /bin/mv "$target" "$backup"; then
        say "failed: couldn't move the old copy aside"
        tidy
        "$opener" "$target"
        exit 1
    fi

    if /bin/mv "$new" "$target"; then
        /bin/rm -rf "$backup"
        /usr/bin/xattr -cr "$target" 2>/dev/null || true
        tidy
        say "installed $target"
        "$opener" "$target"
        exit 0
    fi

    # Put the old copy back, removing whatever half-moved copy is in its place.
    say "failed: couldn't move the new copy in; restoring the old one"
    if [ -d "$backup" ]; then
        /bin/rm -rf "$target"
        /bin/mv "$backup" "$target"
    fi
    tidy
    "$opener" "$target"
    exit 1
    """#
}
