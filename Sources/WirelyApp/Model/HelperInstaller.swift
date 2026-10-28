import Foundation
import WirelyCore

enum InstallerError: Error, LocalizedError {
    case cancelled, missingBundleFiles, failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return L10n.shared(.errInstallCancelled)
        case .missingBundleFiles: return L10n.shared(.errInstallMissingFiles)
        case .failed(let msg): return L10n.shared.format(.errInstallFailed, msg)
        }
    }
}

enum HelperInstaller {
    /// `'` -> `'\''`, wrapped in single quotes.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func install(allowedUID: uid_t) throws {
        let macOS = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS")
        let helperSrc = macOS.appendingPathComponent("wirely-helper")
        let wgSrc = macOS.appendingPathComponent("wireguard-go")
        let fm = FileManager.default
        guard fm.fileExists(atPath: helperSrc.path), fm.fileExists(atPath: wgSrc.path) else {
            throw InstallerError.missingBundleFiles
        }

        let tmp = fm.temporaryDirectory.appendingPathComponent("wirely-install-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw InstallerError.failed(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: tmp) }

        let plist: [String: Any] = [
            "Label": HelperConstants.label,
            "ProgramArguments": [HelperConstants.helperInstallPath, "daemon",
                                 "--allowed-uid", String(allowedUID),
                                 "--wireguard-go", HelperConstants.wireguardGoInstallPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardErrorPath": HelperConstants.logPath,
        ]
        let plistURL = tmp.appendingPathComponent("helper.plist")
        let scriptURL = tmp.appendingPathComponent("install.sh")
        let q = shellQuote
        let script = """
        #!/bin/sh
        /bin/launchctl bootout system/\(HelperConstants.label) 2>/dev/null
        # Remove a Wirely service installed under an earlier identifier (it would hold the same socket).
        for p in /Library/LaunchDaemons/*.wirely.helper.plist; do
            [ -e "$p" ] || continue
            [ "$p" = \(q(HelperConstants.plistPath)) ] && continue
            /bin/launchctl bootout system/"$(/usr/bin/basename "$p" .plist)" 2>/dev/null
            /bin/rm -f "$p"
        done
        for f in /Library/PrivilegedHelperTools/*.wirely.helper /Library/PrivilegedHelperTools/*.wirely.wireguard-go; do
            [ -e "$f" ] || continue
            case "$f" in \(q(HelperConstants.helperInstallPath))|\(q(HelperConstants.wireguardGoInstallPath))) continue;; esac
            /bin/rm -f "$f"
        done
        set -e
        /bin/mkdir -p /Library/PrivilegedHelperTools /Library/Logs/Wirely
        /bin/cp -X \(q(helperSrc.path)) \(q(HelperConstants.helperInstallPath))
        /bin/cp -X \(q(wgSrc.path)) \(q(HelperConstants.wireguardGoInstallPath))
        /usr/sbin/chown root:wheel \(q(HelperConstants.helperInstallPath)) \(q(HelperConstants.wireguardGoInstallPath))
        /bin/chmod 755 \(q(HelperConstants.helperInstallPath)) \(q(HelperConstants.wireguardGoInstallPath))
        /usr/bin/xattr -c \(q(HelperConstants.helperInstallPath)) \(q(HelperConstants.wireguardGoInstallPath))
        /bin/cp -X \(q(plistURL.path)) \(q(HelperConstants.plistPath))
        /usr/sbin/chown root:wheel \(q(HelperConstants.plistPath))
        /bin/chmod 644 \(q(HelperConstants.plistPath))
        n=0
        until /bin/launchctl bootstrap system \(q(HelperConstants.plistPath)); do
            n=$((n+1))
            [ "$n" -ge 5 ] && exit 1
            sleep 1
        done

        """
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            throw InstallerError.failed(error.localizedDescription)
        }
        try runPrivileged("/bin/sh \(q(scriptURL.path))")
    }

    static func uninstall() throws {
        let q = shellQuote
        let cmd = "/bin/launchctl bootout system/\(HelperConstants.label) 2>/dev/null; "
            + "/bin/rm -f \(q(HelperConstants.plistPath)) \(q(HelperConstants.helperInstallPath)) "
            + q(HelperConstants.wireguardGoInstallPath)
        try runPrivileged(cmd)
    }

    /// Runs `command` as root through an AppleScript administrator prompt.
    private static func runPrivileged(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do { try p.run() } catch { throw InstallerError.failed(error.localizedDescription) }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return }
        let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.contains("-128") { throw InstallerError.cancelled }
        throw InstallerError.failed(msg.isEmpty ? L10n.shared.format(.errExitCode, String(p.terminationStatus)) : msg)
    }
}
