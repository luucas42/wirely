import Foundation

/// pf rules and `pfctl` commands for the kill switch.
///
/// The rules live in their own anchor under `com.apple/`, which macOS's stock /etc/pf.conf already
/// evaluates (`anchor "com.apple/*"`), so Wirely never edits the system ruleset. Every rule is
/// `quick`: the first match wins and the final `block` drops everything not explicitly allowed.
public enum KillSwitchPlan {
    public static let pfctl = "/sbin/pfctl"
    public static let anchor = "com.apple/250.Wirely"
    /// Last destination port the kill switch lets a UDP trace probe use (the first is `TraceCollector.udpBasePort`).
    public static let traceLastPort: UInt16 = 34000

    /// Destinations that stay reachable with "Allow local network".
    public static let lanV4 = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
                               "224.0.0.0/4", "255.255.255.255"]
    public static let lanV4Sources = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"]
    public static let lanV6 = ["fe80::/10", "ff00::/8"]

    /// - Parameters:
    ///   - iface: the tunnel interface, or nil when no tunnel is up (blocking after a drop).
    ///   - endpoints: resolved WireGuard servers (literal IP host + port); their UDP stays allowed so
    ///     the tunnel can come back.
    ///   - allowLAN: keep the local network (printers, AirDrop, NAS…) reachable.
    ///   - allowDNS: temporarily allow DNS anywhere so a hostname endpoint can be resolved while
    ///     reconnecting under the kill switch.
    public static func rules(iface: String?, endpoints: [Endpoint], allowLAN: Bool, allowDNS: Bool = false) -> String {
        var lines = ["# Wirely kill switch (generated)",
                     "pass quick on lo0 all flags any keep state"]
        if let iface {
            lines.append("pass quick on \(iface) all flags any keep state")
        }
        for ep in endpoints {
            guard let ip = IPAddress(ep.host) else { continue }
            let family = ip.family == .v4 ? "inet" : "inet6"
            lines.append("pass out quick \(family) proto udp from any to \(ip) port \(ep.port) keep state")
            // Lets a route trace (UDP probes) reach the server from outside the tunnel while everything else is blocked.
            if ip.family == .v4 {
                lines.append("pass out quick inet proto udp from any to \(ip) "
                             + "port \(TraceCollector.udpBasePort):\(traceLastPort) keep state")
            }
        }
        // DHCP must keep working or the lease runs out and the physical link drops.
        lines.append("pass out quick inet proto udp from any port 68 to any port 67 keep state")
        lines.append("pass in quick inet proto udp from any port 67 to any port 68 keep state")
        if allowLAN {
            lines.append("pass out quick inet from any to { \(lanV4.joined(separator: ", ")) } flags any keep state")
            // Inbound only: an outbound rule keyed on our own LAN source address would match everything.
            lines.append("pass in quick inet from { \(lanV4Sources.joined(separator: ", ")) } to any flags any keep state")
            lines.append("pass out quick inet6 from any to { \(lanV6.joined(separator: ", ")) } flags any keep state")
            lines.append("pass in quick inet6 from fe80::/10 to any flags any keep state")
        }
        if allowDNS {
            lines.append("pass out quick proto { udp tcp } from any to any port 53 keep state")
        }
        // ICMP errors (TTL expired, unreachable) are harmless and answer our trace probes.
        lines.append("pass in quick inet proto icmp from any to any icmp-type timex")
        lines.append("pass in quick inet proto icmp from any to any icmp-type unreach")
        lines.append("block drop quick all")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func load(file: String) -> NetCommand { NetCommand(pfctl, ["-a", anchor, "-f", file]) }
    public static let flush = NetCommand(pfctl, ["-a", anchor, "-F", "rules"])
    public static let showRules = NetCommand(pfctl, ["-a", anchor, "-s", "rules"])
    /// Enables pf and takes a reference ("Token : N"), so pf stays on as long as anyone holds one.
    public static let enable = NetCommand(pfctl, ["-E"])
    public static func release(token: String) -> NetCommand { NetCommand(pfctl, ["-X", token]) }

    /// The reference token printed by `pfctl -E` (it may arrive on stdout or stderr).
    public static func parseToken(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "Token", !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) {
                return parts[1]
            }
        }
        return nil
    }
}
