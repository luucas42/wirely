import Foundation
import WirelyCore

public struct CommandResult: Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunner: AnyObject {
    func run(_ command: NetCommand) -> CommandResult
}

public protocol WireGuardLauncher: AnyObject {
    /// Starts wireguard-go and returns the interface name, e.g. "utun7".
    func start() throws -> String
    func configure(_ uapiSet: String) throws
    func get() throws -> String
    func stop()
    var pid: Int32? { get }
    var onUnexpectedExit: (() -> Void)? { get set }
}

public protocol EndpointResolver {
    func resolve(_ endpoint: Endpoint) throws -> IPAddress
}

public protocol StateStore: AnyObject {
    func save(_ state: PersistedState) throws
    func load() -> PersistedState?
    func clear()
}

public struct EndpointRoute: Equatable, Codable {
    public var ip: IPAddress
    /// The command that was used to add the route.
    public var command: NetCommand
    public init(ip: IPAddress, command: NetCommand) {
        self.ip = ip
        self.command = command
    }
}

public struct PersistedState: Equatable, Codable {
    public var tunnelName: String
    public var interface: String
    public var wireguardPID: Int32?
    public var endpointRoutes: [EndpointRoute]
    public var dnsBackups: [DNSBackup]
    public var dnsServers: [IPAddress]
    public var dnsSearch: [String]
    public var connectedAt: Date
    public var ignoredKeys: [String]
    /// Reject routes (families without a tunnel address). They live on lo0 and must be deleted explicitly.
    public var rejectRoutes: [IPNetwork]

    public init(tunnelName: String, interface: String, wireguardPID: Int32?,
                endpointRoutes: [EndpointRoute], dnsBackups: [DNSBackup],
                dnsServers: [IPAddress], dnsSearch: [String],
                connectedAt: Date, ignoredKeys: [String], rejectRoutes: [IPNetwork] = []) {
        self.tunnelName = tunnelName
        self.interface = interface
        self.wireguardPID = wireguardPID
        self.endpointRoutes = endpointRoutes
        self.dnsBackups = dnsBackups
        self.dnsServers = dnsServers
        self.dnsSearch = dnsSearch
        self.connectedAt = connectedAt
        self.ignoredKeys = ignoredKeys
        self.rejectRoutes = rejectRoutes
    }

    private enum CodingKeys: String, CodingKey {
        case tunnelName, interface, wireguardPID, endpointRoutes, dnsBackups, dnsServers, dnsSearch
        case connectedAt, ignoredKeys, rejectRoutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tunnelName = try c.decode(String.self, forKey: .tunnelName)
        interface = try c.decode(String.self, forKey: .interface)
        wireguardPID = try c.decodeIfPresent(Int32.self, forKey: .wireguardPID)
        endpointRoutes = try c.decode([EndpointRoute].self, forKey: .endpointRoutes)
        dnsBackups = try c.decode([DNSBackup].self, forKey: .dnsBackups)
        dnsServers = try c.decode([IPAddress].self, forKey: .dnsServers)
        dnsSearch = try c.decode([String].self, forKey: .dnsSearch)
        connectedAt = try c.decode(Date.self, forKey: .connectedAt)
        ignoredKeys = try c.decode([String].self, forKey: .ignoredKeys)
        rejectRoutes = try c.decodeIfPresent([IPNetwork].self, forKey: .rejectRoutes) ?? []
    }
}

public enum TunnelError: Error, LocalizedError, Equatable {
    case config(ConfigError)
    case resolve(String)
    case commandFailed(String)
    case wireguard(String)

    public var errorDescription: String? {
        switch self {
        case .config(let e): return e.errorDescription
        case .resolve(let host): return "Sunucu adresi çözülemedi: \(host)"
        case .commandFailed(let cmd): return "Komut başarısız: \(cmd)"
        case .wireguard(let msg): return "wireguard-go hatası: \(msg)"
        }
    }

    /// Stable code + main argument for the app's localised error text.
    public var codeAndArg: (code: String, arg: String?) {
        switch self {
        case .config(let e):
            switch e {
            case .missingInterfaceSection: return ("config.missingInterfaceSection", nil)
            case .missingPrivateKey: return ("config.missingPrivateKey", nil)
            case .noPeers: return ("config.noPeers", nil)
            case .invalidKey(let field): return ("config.invalidKey", field)
            case .invalidValue(let key, _): return ("config.invalidValue", key)
            case .unsupportedKey(let key): return ("config.unsupportedKey", key)
            case .unknownSection(let name): return ("config.unknownSection", name)
            case .syntax(let line): return ("config.syntax", String(line))
            }
        case .resolve(let host): return ("resolve", host)
        case .commandFailed(let cmd): return ("commandFailed", cmd)
        case .wireguard(let msg): return ("wireguard", msg)
        }
    }
}
