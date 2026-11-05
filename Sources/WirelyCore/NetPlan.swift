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

    // MARK: Split tunnel

    /// Makes the system resolver forget cached answers (after DNS or split-rule changes).
    public static let flushDNSCache: [NetCommand] = [
        NetCommand("/usr/bin/dscacheutil", ["-flushcache"]),
        NetCommand("/usr/bin/killall", ["-HUP", "mDNSResponder"]),
    ]

    /// Routes for "only selected" mode: address/network rules, the profile's non-default AllowedIPs and
    /// host routes to its DNS servers. No default-route halves, no reject routes.
    public static func splitTargets(config: TunnelConfig, rules: [SplitRule]) -> [IPNetwork] {
        if config.interface.tableOff { return [] }
        var seen = Set<IPNetwork>()
        var out: [IPNetwork] = []
        func add(_ n: IPNetwork) {
            if seen.insert(n).inserted { out.append(n) }
        }
        func host(_ a: IPAddress) -> IPNetwork {
            IPNetwork(address: a, prefixLength: a.family == .v4 ? 32 : 128)
        }
        for rule in rules {
            switch rule {
            case .domain: break
            case .address(let a): add(host(a))
            case .network(let n): add(n)
            }
        }
        for n in SplitCoverage.profileNetworks(config) { add(n) }
        for d in config.interface.dnsServers { add(host(d)) }
        return out
    }

    /// Route for one learned address through the tunnel interface.
    public static func hostRouteAdd(_ ip: IPAddress, iface: String) -> NetCommand {
        NetCommand(route, ["-q", "-n", "add", ip.family == .v4 ? "-inet" : "-inet6", ip.description, "-interface", iface])
    }

    // MARK: Split tunnel, exclude mode

    /// Route for one excluded address/network through the physical default gateway (same fallback as
    /// `endpointRouteAdd`). A host address is written without a prefix length.
    public static func bypassRouteAdd(_ net: IPNetwork, routes: DefaultRoutes) -> NetCommand {
        let v4 = net.address.family == .v4
        let family = v4 ? "-inet" : "-inet6"
        let gateway = v4 ? routes.v4Gateway : routes.v6Gateway
        let iface = v4 ? routes.v4Interface : routes.v6Interface
        let isHost = net.prefixLength == (v4 ? 32 : 128)
        let base = ["-q", "-n", "add", family, isHost ? net.address.description : net.description]
        if let gateway {
            return NetCommand(route, base + ["-gateway", gateway])
        }
        if let iface {
            return NetCommand(route, base + ["-interface", iface])
        }
        return NetCommand(route, base + [v4 ? "127.0.0.1" : "::1", "-blackhole"])
    }

    /// Directly connected IPv4 networks from `ifconfig <iface>` output (`inet <addr> netmask 0x<hex> ...`).
    /// Host bits are masked; point-to-point (`-->`) lines are skipped.
    public static func parseIPv4Subnets(ifconfig: String) -> [IPNetwork] {
        var out: [IPNetwork] = []
        for line in ifconfig.split(whereSeparator: \.isNewline) {
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard t.count >= 4, t[0] == "inet", !t.contains("-->"), t[2] == "netmask",
                  let addr = IPAddress(t[1]), addr.family == .v4,
                  t[3].hasPrefix("0x"), let mask = UInt32(t[3].dropFirst(2), radix: 16) else { continue }
            // Only contiguous masks (a run of ones from the top).
            let ones = mask.nonzeroBitCount
            guard mask == (ones == 0 ? 0 : UInt32.max << UInt32(32 - ones)) else { continue }
            var bytes = addr.bytes
            for i in 0..<4 { bytes[i] &= UInt8(truncatingIfNeeded: mask >> UInt32(24 - 8 * i)) }
            guard let masked = IPAddress(bytes.map(String.init).joined(separator: ".")) else { continue }
            let net = IPNetwork(address: masked, prefixLength: ones)
            if !out.contains(net) { out.append(net) }
        }
        return out
    }

    public static func hostRouteDelete(_ ip: IPAddress) -> NetCommand {
        NetCommand(route, ["-q", "-n", "delete", ip.family == .v4 ? "-inet" : "-inet6", ip.description])
    }
}
