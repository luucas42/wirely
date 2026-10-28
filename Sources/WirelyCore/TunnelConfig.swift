import CryptoKit
import Foundation

public struct InterfaceSection: Equatable, Codable {
    public var privateKey: Data
    public var listenPort: UInt16?
    public var addresses: [IPNetwork]
    public var dnsServers: [IPAddress]
    public var dnsSearchDomains: [String]
    public var mtu: Int?
    public var tableOff: Bool

    public init(privateKey: Data, listenPort: UInt16?, addresses: [IPNetwork], dnsServers: [IPAddress],
                dnsSearchDomains: [String], mtu: Int?, tableOff: Bool) {
        self.privateKey = privateKey
        self.listenPort = listenPort
        self.addresses = addresses
        self.dnsServers = dnsServers
        self.dnsSearchDomains = dnsSearchDomains
        self.mtu = mtu
        self.tableOff = tableOff
    }
}

public struct PeerSection: Equatable, Codable {
    public var publicKey: Data
    public var presharedKey: Data?
    public var endpoint: Endpoint?
    public var allowedIPs: [IPNetwork]
    public var persistentKeepalive: UInt16?

    public init(publicKey: Data, presharedKey: Data?, endpoint: Endpoint?, allowedIPs: [IPNetwork],
                persistentKeepalive: UInt16?) {
        self.publicKey = publicKey
        self.presharedKey = presharedKey
        self.endpoint = endpoint
        self.allowedIPs = allowedIPs
        self.persistentKeepalive = persistentKeepalive
    }
}

public enum ConfigError: Error, Equatable, LocalizedError {
    case missingInterfaceSection, missingPrivateKey, noPeers
    case invalidKey(field: String)
    case invalidValue(key: String, value: String)
    case unsupportedKey(String)
    case unknownSection(String)
    case syntax(line: Int)

    public var errorDescription: String? {
        switch self {
        case .missingInterfaceSection: return "Dosyada [Interface] bölümü yok"
        case .missingPrivateKey: return "[Interface] bölümünde PrivateKey yok"
        case .noPeers: return "Dosyada [Peer] bölümü yok"
        case .invalidKey(let field): return "Geçersiz anahtar: \(field) (32 baytlık base64 olmalı)"
        case .invalidValue(let key, let value): return "\(key) için geçersiz değer: \(value)"
        case .unsupportedKey(let key): return "Desteklenmeyen ayar: \(key) (AmneziaWG gibi eklentiler desteklenmiyor)"
        case .unknownSection(let name): return "Bilinmeyen bölüm: [\(name)]"
        case .syntax(let line): return "Söz dizimi hatası, satır \(line)"
        }
    }
}

public struct TunnelConfig: Equatable, Codable {
    public var interface: InterfaceSection
    public var peers: [PeerSection]
    public var ignoredKeys: [String]

    public init(interface: InterfaceSection, peers: [PeerSection], ignoredKeys: [String]) {
        self.interface = interface
        self.peers = peers
        self.ignoredKeys = ignoredKeys
    }

    public var routesAllTraffic: Bool {
        peers.contains { $0.allowedIPs.contains { $0.prefixLength == 0 } }
    }

    public var interfacePublicKey: Data {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: interface.privateKey) else {
            return Data()
        }
        return key.publicKey.rawRepresentation
    }

    private static let interfaceKeys = ["PrivateKey", "ListenPort", "Address", "DNS", "MTU", "Table"]
    private static let peerKeys = ["PublicKey", "PresharedKey", "Endpoint", "AllowedIPs", "PersistentKeepalive"]
    private static let ignorable = ["PreUp", "PostUp", "PreDown", "PostDown", "SaveConfig", "FwMark"]

    private static func canonical(_ key: String) -> String? {
        let lower = key.lowercased()
        return (interfaceKeys + peerKeys + ignorable).first { $0.lowercased() == lower }
    }

    private static func decodeKey(_ value: String, field: String) throws -> Data {
        guard let d = Data(base64Encoded: value), d.count == 32 else { throw ConfigError.invalidKey(field: field) }
        return d
    }

    private static func commaList(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private struct PeerDraft {
        var publicKey: Data?
        var presharedKey: Data?
        var endpoint: Endpoint?
        var allowedIPs: [IPNetwork] = []
        var keepalive: UInt16?
    }

    private enum Section { case none, interface, peer }

    public static func parse(_ text: String) throws -> TunnelConfig {
        var section = Section.none
        var sawInterface = false
        var privateKey: Data?
        var listenPort: UInt16?
        var addresses: [IPNetwork] = []
        var dnsServers: [IPAddress] = []
        var dnsDomains: [String] = []
        var mtu: Int?
        var tableOff = false
        var ignored: [String] = []
        var peers: [PeerDraft] = []

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        for (idx, raw) in lines.enumerated() {
            let lineNo = idx + 1
            var line = raw
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw ConfigError.syntax(line: lineNo) }
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                switch name.lowercased() {
                case "interface":
                    if sawInterface { throw ConfigError.syntax(line: lineNo) }
                    sawInterface = true
                    section = .interface
                case "peer":
                    section = .peer
                    peers.append(PeerDraft())
                default:
                    throw ConfigError.unknownSection(name)
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { throw ConfigError.syntax(line: lineNo) }
            let rawKey = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard section != .none, !rawKey.isEmpty else { throw ConfigError.syntax(line: lineNo) }
            guard let key = canonical(rawKey) else { throw ConfigError.unsupportedKey(rawKey) }

            if ignorable.contains(key) {
                if !ignored.contains(key) { ignored.append(key) }
                continue
            }
            func invalid() -> ConfigError { .invalidValue(key: key, value: value) }

            switch section {
            case .interface:
                guard interfaceKeys.contains(key) else { throw ConfigError.unsupportedKey(rawKey) }
                switch key {
                case "PrivateKey": privateKey = try decodeKey(value, field: key)
                case "ListenPort":
                    guard let p = UInt16(value) else { throw invalid() }
                    listenPort = p
                case "Address":
                    for item in commaList(value) {
                        guard let n = IPNetwork(item) else { throw invalid() }
                        addresses.append(n)
                    }
                case "DNS":
                    for item in commaList(value) {
                        if let ip = IPAddress(item) { dnsServers.append(ip) } else { dnsDomains.append(item) }
                    }
                case "MTU":
                    guard let m = Int(value), (576...9000).contains(m) else { throw invalid() }
                    mtu = m
                default: // Table
                    switch value.lowercased() {
                    case "off": tableOff = true
                    case "auto", "main": tableOff = false
                    default: throw invalid()
                    }
                }
            case .peer:
                guard peerKeys.contains(key) else { throw ConfigError.unsupportedKey(rawKey) }
                var peer = peers[peers.count - 1]
                switch key {
                case "PublicKey": peer.publicKey = try decodeKey(value, field: key)
                case "PresharedKey": peer.presharedKey = try decodeKey(value, field: key)
                case "Endpoint":
                    guard let e = Endpoint(value) else { throw invalid() }
                    peer.endpoint = e
                case "AllowedIPs":
                    for item in commaList(value) {
                        guard let n = IPNetwork(item) else { throw invalid() }
                        peer.allowedIPs.append(n)
                    }
                default: // PersistentKeepalive
                    guard let k = UInt16(value) else { throw invalid() }
                    peer.keepalive = k
                }
                peers[peers.count - 1] = peer
            case .none:
                throw ConfigError.syntax(line: lineNo)
            }
        }

        guard sawInterface else { throw ConfigError.missingInterfaceSection }
        guard let privateKey else { throw ConfigError.missingPrivateKey }
        guard !peers.isEmpty else { throw ConfigError.noPeers }

        let built = try peers.map { d -> PeerSection in
            guard let pub = d.publicKey else { throw ConfigError.invalidKey(field: "PublicKey") }
            return PeerSection(publicKey: pub, presharedKey: d.presharedKey, endpoint: d.endpoint,
                               allowedIPs: d.allowedIPs, persistentKeepalive: d.keepalive)
        }
        return TunnelConfig(
            interface: InterfaceSection(privateKey: privateKey, listenPort: listenPort, addresses: addresses,
                                        dnsServers: dnsServers, dnsSearchDomains: dnsDomains, mtu: mtu,
                                        tableOff: tableOff),
            peers: built, ignoredKeys: ignored)
    }
}
