import Foundation

public enum HelperConstants {
    public static let socketPath = "/var/run/wirely-helper.sock"
    public static let label = "io.github.luucas42.wirely.helper"
    public static let helperVersion = 5
    public static let helperInstallPath = "/Library/PrivilegedHelperTools/io.github.luucas42.wirely.helper"
    public static let wireguardGoInstallPath = "/Library/PrivilegedHelperTools/io.github.luucas42.wirely.wireguard-go"
    public static let plistPath = "/Library/LaunchDaemons/io.github.luucas42.wirely.helper.plist"
    public static let logPath = "/Library/Logs/Wirely/helper.log"
    public static let statePath = "/Library/Application Support/Wirely/state.json"
}

public enum TunnelState: String, Codable { case disconnected, connecting, connected, failed }

public struct TunnelStatus: Equatable, Codable {
    public var state: TunnelState
    public var tunnelName: String?
    public var interface: String?
    public var connectedAt: Date?
    public var lastHandshake: Date?
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var endpoint: String?
    public var message: String?
    public var ignoredKeys: [String]

    public init(state: TunnelState, tunnelName: String? = nil, interface: String? = nil,
                connectedAt: Date? = nil, lastHandshake: Date? = nil,
                rxBytes: UInt64 = 0, txBytes: UInt64 = 0,
                endpoint: String? = nil, message: String? = nil, ignoredKeys: [String] = []) {
        self.state = state
        self.tunnelName = tunnelName
        self.interface = interface
        self.connectedAt = connectedAt
        self.lastHandshake = lastHandshake
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.endpoint = endpoint
        self.message = message
        self.ignoredKeys = ignoredKeys
    }

    public static let disconnected = TunnelStatus(state: .disconnected)
}

public enum HelperCommand: String, Codable { case up, down, status, version }

public struct HelperRequest: Codable, Equatable {
    public var command: HelperCommand
    public var tunnelName: String?
    public var config: String?
    public init(command: HelperCommand, tunnelName: String? = nil, config: String? = nil) {
        self.command = command
        self.tunnelName = tunnelName
        self.config = config
    }
}

public struct HelperResponse: Codable, Equatable {
    public var ok: Bool
    public var error: String?
    public var status: TunnelStatus?
    public var helperVersion: Int
    /// Machine-readable error code (e.g. "config.syntax", "resolve") so the app can localise `error`.
    public var errorCode: String?
    /// The code's main value (host, key, command, line number…), if any.
    public var errorArg: String?
    public init(ok: Bool, error: String?, status: TunnelStatus?, helperVersion: Int,
                errorCode: String? = nil, errorArg: String? = nil) {
        self.ok = ok
        self.error = error
        self.errorCode = errorCode
        self.errorArg = errorArg
        self.status = status
        self.helperVersion = helperVersion
    }
}
