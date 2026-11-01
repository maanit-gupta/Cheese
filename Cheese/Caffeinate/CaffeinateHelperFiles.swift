import Foundation

/// The root helper behind "Keep Awake With Lid Closed", as plain strings so every byte that runs
/// as root is unit-tested.
///
/// Keeping a Mac awake with the lid shut needs `pmset -a disablesleep 1`, which only root may run.
/// Cheese installs a small shell script once, behind one administrator prompt, as a launchd daemon
/// that runs at boot and whenever Cheese changes its request file. While Cheese (and only Cheese)
/// asks, it disables lid-close sleep; as soon as the request goes, runs out, the battery falls to
/// the floor, or Cheese quits or crashes, it puts it back, and sleeps a Mac whose lid is shut when
/// the time ran out. A marker it owns survives restarts, so a session cut short by one is undone
/// at boot. It idles at no cost: launchd only starts it when the request changes.
///
/// The helper never writes into the user-owned request folder, never follows a symlinked request,
/// accepts nothing but three numbers from it, and never changes `SleepDisabled` it didn't set.
enum CaffeinateHelperFiles {
    /// Bumped whenever the script changes, so Cheese reinstalls an older helper.
    static let version = 1
    static let versionLine = "# cheese-caffeinate-helper v\(version)"

    static let label = "com.maanitgupta.cheese.caffeinate"
    static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    /// Root-owned; holds the two folders below.
    static let supportFolder = "/Library/Application Support/Cheese"
    /// Owned by the user who installed the helper, so Cheese can write its request there.
    static let requestFolder = supportFolder + "/Caffeinate"
    static let requestPath = requestFolder + "/request"
    /// Root-owned, readable by everyone: the `owned` marker and the last session's `status`.
    static let stateFolder = supportFolder + "/CaffeinateRoot"
    static let ownedMarkerPath = stateFolder + "/owned"
    static let statusPath = stateFolder + "/status"

    /// The tools and places the helper uses. Tests swap in stubs and temporary folders.
    struct Environment: Equatable, Sendable {
        var pmset = PrivilegedShell.pmset
        var ioreg = "/usr/sbin/ioreg -r -k AppleClamshellState -d 1"
        var ps = "/bin/ps"
        var requestPath = CaffeinateHelperFiles.requestPath
        var stateFolder = CaffeinateHelperFiles.stateFolder
        var interval = "2"
        /// Only a process whose executable ends with this may keep the Mac awake.
        var executableSuffix = "/Contents/MacOS/Cheese"

        static let system = Environment()
    }

    /// The helper script, run by launchd as root.
    static func helperScript(_ env: Environment = .system) -> String {
        """
        #!/bin/sh
        \(versionLine)
        # Keeps the Mac awake with the lid closed while Cheese asks it to. Run by launchd at boot
        # and whenever Cheese changes its request file. Installed by Cheese; remove it in
        # Cheese Settings → Caffeinate.
        set -f
        PMSET=\(PrivilegedShell.shellQuoted(env.pmset))
        IOREG=\(PrivilegedShell.shellQuoted(env.ioreg))
        PS=\(PrivilegedShell.shellQuoted(env.ps))
        REQUEST=\(PrivilegedShell.shellQuoted(env.requestPath))
        STATE=\(PrivilegedShell.shellQuoted(env.stateFolder))
        INTERVAL=\(PrivilegedShell.shellQuoted(env.interval))
        SUFFIX=\(PrivilegedShell.shellQuoted(env.executableSuffix))
        OWNED="$STATE/owned"
        reason=off

        number() {
          case "$1" in ""|*[!0-9]*) return 1;; esac
          [ ${#1} -le 12 ]
        }

        # Whether Cheese still wants the Mac awake. Sets reason to expired or battery when that's
        # why not.
        wanted() {
          reason=off
          [ -f "$REQUEST" ] && [ ! -L "$REQUEST" ] || return 1
          set -- $(head -c 64 "$REQUEST" 2>/dev/null)
          [ $# -eq 3 ] && number "$1" && number "$2" && number "$3" || return 1
          pid=$1; deadline=$2; floor=$3
          kill -0 "$pid" 2>/dev/null || return 1
          case "$($PS -p "$pid" -o comm= 2>/dev/null)" in *"$SUFFIX") ;; *) return 1;; esac
          if [ "$deadline" -gt 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then reason=expired; return 1; fi
          if [ "$floor" -gt 0 ]; then
            batt=$($PMSET -g batt 2>/dev/null)
            case "$batt" in
              *"'Battery Power'"*)
                pct=$(printf '%s\\n' "$batt" | sed -n 's/.*[^0-9]\\([0-9][0-9]*\\)%;.*/\\1/p' | head -n 1)
                if [ -n "$pct" ] && [ "$pct" -le "$floor" ]; then reason=battery; return 1; fi
                ;;
            esac
          fi
          return 0
        }

        while wanted; do
          if [ ! -f "$OWNED" ]; then
            $PMSET -a disablesleep 1 && : > "$OWNED" && printf 'active\\n' > "$STATE/status"
          fi
          sleep "$INTERVAL"
        done

        if [ -f "$OWNED" ]; then
          $PMSET -a disablesleep 0
          rm -f "$OWNED"
          printf '%s\\n' "$reason" > "$STATE/status"
          if [ "$reason" != off ]; then
            # macOS only sleeps when the lid closes, so a lid shut during the session would keep
            # the Mac awake. Leave a lid shut on an external display alone, as macOS would.
            lid=$($IOREG 2>/dev/null)
            case "$lid" in
              *'"AppleClamshellState" = Yes'*)
                case "$lid" in *'"AppleClamshellCausesSleep" = Yes'*) $PMSET sleepnow ;; esac
                ;;
            esac
          fi
        fi
        exit 0

        """
    }

    /// The launchd job: at boot, and whenever the request folder changes.
    static func launchDaemonPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/sh</string>
                <string>\(xmlEscaped(helperPath))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>WatchPaths</key>
            <array>
                <string>\(xmlEscaped(requestFolder))</string>
            </array>
            <key>KeepAlive</key>
            <false/>
            <key>ThrottleInterval</key>
            <integer>1</integer>
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>com.maanitgupta.cheese</string>
            </array>
        </dict>
        </plist>

        """
    }

    /// Installs (or reinstalls) the helper, run as root. `uid` owns the request folder. Writes
    /// every root file from this script's own text, never copying a file the user could change.
    static func installScript(uid: UInt32) -> String {
        let helper = PrivilegedShell.shellQuoted(helperPath)
        let plist = PrivilegedShell.shellQuoted(plistPath)
        let support = PrivilegedShell.shellQuoted(supportFolder)
        let request = PrivilegedShell.shellQuoted(requestFolder)
        let state = PrivilegedShell.shellQuoted(stateFolder)
        return [
            "/bin/launchctl bootout system/\(label) >/dev/null 2>&1; true",
            "/bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons \(support)",
            // Folders Cheese creates must be real folders, not links planted elsewhere.
            "[ ! -L \(support) ] && [ ! -L \(request) ] && [ ! -L \(state) ]",
            "/usr/sbin/chown root:wheel \(support) && /bin/chmod 755 \(support)",
            "/bin/mkdir -p \(request) \(state)",
            "/usr/sbin/chown \(uid) \(request) && /bin/chmod 755 \(request)",
            "/usr/sbin/chown root:wheel \(state) && /bin/chmod 755 \(state)",
            "/bin/rm -f \(helper) \(plist)",
            "printf '%s' \(PrivilegedShell.shellQuoted(helperScript())) > \(helper)",
            "/usr/sbin/chown root:wheel \(helper) && /bin/chmod 755 \(helper)",
            "printf '%s' \(PrivilegedShell.shellQuoted(launchDaemonPlist())) > \(plist)",
            "/usr/sbin/chown root:wheel \(plist) && /bin/chmod 644 \(plist)",
            "/bin/launchctl bootstrap system \(plist)",
        ].joined(separator: " && ")
    }

    /// Removes the helper and everything it made, putting lid-close sleep back if it had it off.
    static let uninstallScript = [
        "/bin/launchctl bootout system/\(label) >/dev/null 2>&1",
        "if [ -f \(PrivilegedShell.shellQuoted(ownedMarkerPath)) ]; then \(PrivilegedShell.pmset) -a disablesleep 0; fi",
        "/bin/rm -f \(PrivilegedShell.shellQuoted(helperPath)) \(PrivilegedShell.shellQuoted(plistPath))",
        "/bin/rm -rf \(PrivilegedShell.shellQuoted(supportFolder))",
    ].joined(separator: "; ")

    /// What Cheese writes to keep the Mac awake: its pid, the Unix time to stop at (0 for no
    /// limit), and the battery percentage to stop at (0 for none).
    static func request(pid: Int32, deadline: Date?, batteryFloor: Int) -> String {
        let end = deadline.map { max(Int($0.timeIntervalSince1970.rounded(.up)), 1) } ?? 0
        return "\(pid) \(end) \(min(max(batteryFloor, 0), 100))\n"
    }

    /// The request that ends a session as if its time ran out, so the helper sleeps a closed Mac.
    static func expiredRequest(pid: Int32, batteryFloor: Int) -> String {
        "\(pid) 1 \(min(max(batteryFloor, 0), 100))\n"
    }

    /// Whether the installed script is this version.
    static func isCurrent(installedScript: String) -> Bool {
        installedScript.split(separator: "\n", maxSplits: 3).contains { $0 == versionLine }
    }

    /// `text` escaped for an XML plist string.
    static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
