import Foundation
import WirelyCore

public struct FirewallError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// The kill switch on macOS's packet filter, through `pfctl` and Wirely's own anchor.
public final class PFFirewall: Firewall {
    private let runner: CommandRunner
    private let rulesPath: String

    public init(runner: CommandRunner, rulesPath: String = "/Library/Application Support/Wirely/killswitch.pf") {
        self.runner = runner
        self.rulesPath = rulesPath
    }

    public func engage(rules: String, token: String?) throws -> String? {
        let dir = (rulesPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(rules.utf8).write(to: URL(fileURLWithPath: rulesPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rulesPath)
        } catch {
            throw FirewallError(message: "kill switch rules: \(error.localizedDescription)")
        }
        let load = runner.run(KillSwitchPlan.load(file: rulesPath))
        guard load.status == 0 else {
            throw FirewallError(message: "pfctl: \(load.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let token { return token }
        let enable = runner.run(KillSwitchPlan.enable)
        guard enable.status == 0 else {
            _ = runner.run(KillSwitchPlan.flush)
            throw FirewallError(message: "pfctl -E: \(enable.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return KillSwitchPlan.parseToken(enable.stdout + "\n" + enable.stderr)
    }

    public func disengage(token: String?) {
        _ = runner.run(KillSwitchPlan.flush)
        if let token { _ = runner.run(KillSwitchPlan.release(token: token)) }
        try? FileManager.default.removeItem(atPath: rulesPath)
    }

    public func isEngaged() -> Bool {
        let r = runner.run(KillSwitchPlan.showRules)
        return r.status == 0 && !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
