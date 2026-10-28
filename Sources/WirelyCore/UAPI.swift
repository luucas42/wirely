import Foundation

public struct PeerSnapshot: Equatable {
    public var publicKey: Data
    public var endpoint: String?
    public var lastHandshake: Date?
    public var rxBytes: UInt64
    public var txBytes: UInt64

    public init(publicKey: Data, endpoint: String?, lastHandshake: Date?, rxBytes: UInt64, txBytes: UInt64) {
        self.publicKey = publicKey
        self.endpoint = endpoint
        self.lastHandshake = lastHandshake
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }
}

public struct DeviceSnapshot: Equatable {
    public var peers: [PeerSnapshot]

    public init(peers: [PeerSnapshot]) { self.peers = peers }

    public var totalRx: UInt64 { peers.reduce(0) { $0 + $1.rxBytes } }
    public var totalTx: UInt64 { peers.reduce(0) { $0 + $1.txBytes } }
    public var latestHandshake: Date? { peers.compactMap(\.lastHandshake).max() }
}

public enum UAPIError: Error, Equatable { case errno(Int), malformed(String) }

public enum UAPI {
    public static func setCommand(_ config: TunnelConfig, resolvedEndpoints: [String?]) -> String {
        var s = "set=1\n"
        s += "private_key=\(config.interface.privateKey.hexString)\n"
        if let port = config.interface.listenPort { s += "listen_port=\(port)\n" }
        s += "replace_peers=true\n"
        for (i, peer) in config.peers.enumerated() {
            s += "public_key=\(peer.publicKey.hexString)\n"
            if let psk = peer.presharedKey { s += "preshared_key=\(psk.hexString)\n" }
            if i < resolvedEndpoints.count, let ep = resolvedEndpoints[i] { s += "endpoint=\(ep)\n" }
            if let k = peer.persistentKeepalive { s += "persistent_keepalive_interval=\(k)\n" }
            s += "replace_allowed_ips=true\n"
            for net in peer.allowedIPs { s += "allowed_ip=\(net)\n" }
        }
        s += "\n"
        return s
    }

    public static func parseGet(_ response: String) throws -> DeviceSnapshot {
        try checkErrno(response)
        var peers: [PeerSnapshot] = []
        var hsSec: Int64 = 0
        var hsNsec: Int64 = 0

        func finishHandshake() {
            guard !peers.isEmpty else { return }
            peers[peers.count - 1].lastHandshake = hsSec == 0
                ? nil : Date(timeIntervalSince1970: Double(hsSec) + Double(hsNsec) / 1e9)
        }

        for line in response.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq]
            let value = String(line[line.index(after: eq)...])
            switch key {
            case "public_key":
                finishHandshake()
                hsSec = 0; hsNsec = 0
                guard let d = Data(hex: value) else { throw UAPIError.malformed("public_key") }
                peers.append(PeerSnapshot(publicKey: d, endpoint: nil, lastHandshake: nil, rxBytes: 0, txBytes: 0))
            case "endpoint" where !peers.isEmpty:
                peers[peers.count - 1].endpoint = value
            case "last_handshake_time_sec" where !peers.isEmpty:
                hsSec = Int64(value) ?? 0
            case "last_handshake_time_nsec" where !peers.isEmpty:
                hsNsec = Int64(value) ?? 0
            case "rx_bytes" where !peers.isEmpty:
                peers[peers.count - 1].rxBytes = UInt64(value) ?? 0
            case "tx_bytes" where !peers.isEmpty:
                peers[peers.count - 1].txBytes = UInt64(value) ?? 0
            default:
                break
            }
        }
        finishHandshake()
        return DeviceSnapshot(peers: peers)
    }

    public static func checkErrno(_ response: String) throws {
        for line in response.split(whereSeparator: \.isNewline) where line.hasPrefix("errno=") {
            guard let n = Int(line.dropFirst("errno=".count)) else { throw UAPIError.malformed("bad errno") }
            if n != 0 { throw UAPIError.errno(n) }
            return
        }
        throw UAPIError.malformed("missing errno")
    }
}
