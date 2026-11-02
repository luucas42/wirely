import Foundation

public enum HelperConstants {
    public static let socketPath = "/var/run/wirely-helper.sock"
    public static let label = "io.github.luucas42.wirely.helper"
    public static let helperVersion = 7
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
    /// The kill switch is armed for this tunnel. With `state == .failed` it means the tunnel dropped
    /// and all traffic is being blocked until the user reconnects or disconnects.
    /// Optional so statuses from older helpers still decode.
    public var killSwitch: Bool?

    public init(state: TunnelState, tunnelName: String? = nil, interface: String? = nil,
                connectedAt: Date? = nil, lastHandshake: Date? = nil,
                rxBytes: UInt64 = 0, txBytes: UInt64 = 0,
                endpoint: String? = nil, message: String? = nil, ignoredKeys: [String] = [],
                killSwitch: Bool? = nil) {
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
        self.killSwitch = killSwitch
    }

    /// Traffic is blocked by the kill switch after the tunnel dropped.
    public var isBlockedByKillSwitch: Bool { state == .failed && killSwitch == true }

    public static let disconnected = TunnelStatus(state: .disconnected)
}

public enum HelperCommand: String, Codable { case up, down, status, version, trace }

public struct HelperRequest: Codable, Equatable {
    public var command: HelperCommand
    public var tunnelName: String?
    public var config: String?
    /// `up` only: arm the kill switch for this tunnel, and whether it lets local-network traffic through.
    public var killSwitch: Bool?
    public var allowLAN: Bool?
    /// `trace` only: host name or IPv4 literal to trace the route to.
    public var traceTarget: String?
    public init(command: HelperCommand, tunnelName: String? = nil, config: String? = nil,
                killSwitch: Bool? = nil, allowLAN: Bool? = nil, traceTarget: String? = nil) {
        self.command = command
        self.tunnelName = tunnelName
        self.config = config
        self.killSwitch = killSwitch
        self.allowLAN = allowLAN
        self.traceTarget = traceTarget
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
    /// `trace` only: the hops found on the way to the target. Optional so older helpers still decode.
    public var trace: TraceResult?
    public init(ok: Bool, error: String?, status: TunnelStatus?, helperVersion: Int,
                errorCode: String? = nil, errorArg: String? = nil, trace: TraceResult? = nil) {
        self.ok = ok
        self.error = error
        self.errorCode = errorCode
        self.errorArg = errorArg
        self.status = status
        self.helperVersion = helperVersion
        self.trace = trace
    }
}

/// One TTL step of a route trace.
public struct TraceHop: Codable, Equatable {
    public var ttl: Int
    /// Dotted IPv4 of the router that answered; nil when nothing answered.
    public var address: String?
    /// Fastest round trip over all probes, in milliseconds.
    public var rttMs: Double?
    /// The target itself answered at this step.
    public var isDestination: Bool
    public init(ttl: Int, address: String?, rttMs: Double?, isDestination: Bool) {
        self.ttl = ttl
        self.address = address
        self.rttMs = rttMs
        self.isDestination = isDestination
    }
}

/// The outcome of a route trace: every hop up to the target (or the last router that answered).
public struct TraceResult: Codable, Equatable {
    public var target: String
    /// The IPv4 address the target resolved to.
    public var address: String
    public var hops: [TraceHop]
    public var durationMs: Int
    /// Some hop is the destination, i.e. the target answered.
    public var reached: Bool
    public init(target: String, address: String, hops: [TraceHop], durationMs: Int, reached: Bool) {
        self.target = target
        self.address = address
        self.hops = hops
        self.durationMs = durationMs
        self.reached = reached
    }
}
