import Foundation

public struct DNSBackup: Equatable, Codable {
    public var service: String
    public var servers: [String]
    public var searchDomains: [String]
    public init(service: String, servers: [String], searchDomains: [String]) {
        self.service = service
        self.servers = servers
        self.searchDomains = searchDomains
    }
}

/// `networksetup` argv planning for per-service DNS.
public enum DNSPlan {
    public static let listServiceOrder = NetCommand(NetPlan.networksetup, ["-listnetworkserviceorder"])

    /// Names of enabled services that have a real device, in order. Services without a
    /// device (other VPN apps such as Tailscale or WireGuard tunnels) are skipped so their
    /// configuration is never touched.
    public static func parseHardwareServices(_ output: String) -> [String] {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard line.hasPrefix("("), let close = line.range(of: ") ") else { continue }
            let number = line[line.index(after: line.startIndex)..<close.lowerBound]
            guard !number.isEmpty, number.allSatisfy(\.isNumber) else { continue }
            let name = String(line[close.upperBound...])
            guard !name.isEmpty, i < lines.count else { continue }
            let detail = lines[i]
            guard detail.hasPrefix("(Hardware Port:"), detail.hasSuffix(")"),
                  let dev = detail.range(of: "Device:", options: .backwards) else { continue }
            let device = detail[dev.upperBound...].dropLast().trimmingCharacters(in: .whitespaces)
            if !device.isEmpty { result.append(name) }
        }
        return result
    }

    public static func parseList(_ output: String) -> [String] {
        if output.contains("There aren't any") { return [] }
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func getServers(_ service: String) -> NetCommand {
        NetCommand(NetPlan.networksetup, ["-getdnsservers", service])
    }

    public static func getSearchDomains(_ service: String) -> NetCommand {
        NetCommand(NetPlan.networksetup, ["-getsearchdomains", service])
    }

    public static func apply(service: String, servers: [IPAddress], search: [String]) -> [NetCommand] {
        build(service: service, servers: servers.map { $0.description }, search: search)
    }

    public static func restore(_ backup: DNSBackup) -> [NetCommand] {
        build(service: backup.service, servers: backup.servers, search: backup.searchDomains)
    }

    private static func build(service: String, servers: [String], search: [String]) -> [NetCommand] {
        [
            NetCommand(NetPlan.networksetup, ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers)),
            NetCommand(NetPlan.networksetup, ["-setsearchdomains", service] + (search.isEmpty ? ["Empty"] : search)),
        ]
    }
}
