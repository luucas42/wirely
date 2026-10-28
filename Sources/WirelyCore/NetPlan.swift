import Foundation

public struct NetCommand: Equatable, Codable, CustomStringConvertible {
    public let path: String
    public let args: [String]
    public init(_ path: String, _ args: [String]) {
        self.path = path
        self.args = args
    }
    public var description: String { ([path] + args).joined(separator: " ") }
}

public struct DefaultRoutes: Equatable, Codable {
    public var v4Gateway: String?
    public var v4Interface: String?
    public var v6Gateway: String?
    public var v6Interface: String?
    public init(v4Gateway: String?, v4Interface: String?, v6Gateway: String?, v6Interface: String?) {
        self.v4Gateway = v4Gateway
        self.v4Interface = v4Interface
        self.v6Gateway = v6Gateway
        self.v6Interface = v6Interface
    }
}

/// Pure planning of the `ifconfig` / `route` invocations that `wg-quick` performs on darwin.
public enum NetPlan {
    public static let ifconfig = "/sbin/ifconfig"
    public static let route = "/sbin/route"
    public static let netstat = "/usr/sbin/netstat"
    public static let networksetup = "/usr/sbin/networksetup"

    public static func netstatCommand(_ family: IPFamily) -> NetCommand {
        NetCommand(netstat, ["-nr", "-f", family == .v4 ? "inet" : "inet6"])
    }

    public static func ifconfigShow(_ iface: String) -> NetCommand {
        NetCommand(ifconfig, [iface])
    }

    public static func parseDefaultRoute(netstat: String) -> (gateway: String?, interface: String?) {
        let skipped = ["utun", "lo", "gif", "stf"]
        for line in netstat.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 4, fields[0] == "default" else { continue }
            let netif = fields[3]
            if skipped.contains(where: { netif.hasPrefix($0) }) { continue }
            let gw = fields[1]
            return (gw.hasPrefix("link#") ? nil : gw, netif)
        }
        return (nil, nil)
    }

    public static func parseMTU(ifconfig: String) -> Int? {
        let tokens = ifconfig.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }).map(String.init)
        guard let i = tokens.firstIndex(of: "mtu"), i + 1 < tokens.count else { return nil }
        return Int(tokens[i + 1])
    }

    public static func tunnelMTU(configured: Int?, physicalMTU: Int?) -> Int {
        configured ?? ((physicalMTU ?? 1500) - 80)
    }

    public static func interfaceCommands(iface: String, addresses: [IPNetwork], mtu: Int) -> [NetCommand] {
        var cmds: [NetCommand] = []
        for a in addresses {
            switch a.address.family {
            case .v4:
                cmds.append(NetCommand(ifconfig, [iface, "inet", a.description, a.address.description, "alias"]))
            case .v6:
                cmds.append(NetCommand(ifconfig, [iface, "inet6", a.description, "alias"]))
            }
        }
        cmds.append(NetCommand(ifconfig, [iface, "mtu", String(mtu)]))
        cmds.append(NetCommand(ifconfig, [iface, "up"]))
        return cmds
    }

    public static func routeTargets(_ config: TunnelConfig) -> [IPNetwork] {
        if config.interface.tableOff { return [] }
        var seen = Set<IPNetwork>()
        var out: [IPNetwork] = []
        func add(_ n: IPNetwork) {
            if seen.insert(n).inserted { out.append(n) }
        }
        for peer in config.peers {
            for n in peer.allowedIPs {
                if n.prefixLength == 0 {
                    switch n.address.family {
                    case .v4:
                        add(IPNetwork("0.0.0.0/1")!)
                        add(IPNetwork("128.0.0.0/1")!)
                    case .v6:
                        add(IPNetwork("::/1")!)
                        add(IPNetwork("8000::/1")!)
                    }
                } else {
                    add(n)
                }
            }
        }
        return out
    }

    /// Targets whose address family has no address on the interface. The utun gets no route table
    /// entries for such a family, so they are blackholed with reject routes instead (no leak).
    public static func rejectedTargets(_ targets: [IPNetwork], addresses: [IPNetwork]) -> [IPNetwork] {
        let families = Set(addresses.map(\.address.family))
        return targets.filter { !families.contains($0.address.family) }
    }

    /// One command per target, in order: `-interface` routes, or reject routes for families without an address.
    public static func routeAddCommands(iface: String, targets: [IPNetwork], addresses: [IPNetwork]) -> [NetCommand] {
        let families = Set(addresses.map(\.address.family))
        return targets.map { t in
            let v4 = t.address.family == .v4
            let family = v4 ? "-inet" : "-inet6"
            if families.contains(t.address.family) {
                return NetCommand(route, ["-q", "-n", "add", family, t.description, "-interface", iface])
            }
            return NetCommand(route, ["-q", "-n", "add", family, t.description, v4 ? "127.0.0.1" : "::1", "-reject"])
        }
    }

    public static func routeDelete(_ net: IPNetwork) -> NetCommand {
        NetCommand(route, ["-q", "-n", "delete", net.address.family == .v4 ? "-inet" : "-inet6", net.description])
    }

    public static func endpointNeedsBypass(_ ip: IPAddress, targets: [IPNetwork]) -> Bool {
        targets.contains { $0.contains(ip) }
    }

    public static func endpointRouteAdd(_ ip: IPAddress, routes: DefaultRoutes) -> NetCommand {
        let v4 = ip.family == .v4
        let family = v4 ? "-inet" : "-inet6"
        let gateway = v4 ? routes.v4Gateway : routes.v6Gateway
        let iface = v4 ? routes.v4Interface : routes.v6Interface
        let base = ["-q", "-n", "add", family, ip.description]
        if let gateway {
            return NetCommand(route, base + ["-gateway", gateway])
        }
        if let iface {
            return NetCommand(route, base + ["-interface", iface])
        }
        return NetCommand(route, base + [v4 ? "127.0.0.1" : "::1", "-blackhole"])
    }

    public static func routeGet(_ ip: IPAddress) -> NetCommand {
        NetCommand(route, ["-n", "get", ip.family == .v4 ? "-inet" : "-inet6", ip.description])
    }

    /// Value of the `interface:` line of `route -n get` output.
    public static func parseRouteGetInterface(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("interface:") else { continue }
            let v = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    public static func endpointRouteDelete(_ ip: IPAddress) -> NetCommand {
        NetCommand(route, ["-q", "-n", "delete", ip.family == .v4 ? "-inet" : "-inet6", ip.description])
    }
}
