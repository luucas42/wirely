import Foundation

/// Which split rules the server (the profile's AllowedIPs) would actually accept traffic for.
public enum SplitCoverage {
    public static func covers(_ ip: IPAddress, config: TunnelConfig) -> Bool {
        config.peers.contains { $0.allowedIPs.contains { $0.contains(ip) } }
    }

    /// Address and network rules WireGuard would drop. Domain rules can't be checked.
    public static func uncovered(rules: [SplitRule], config: TunnelConfig) -> Set<SplitRule> {
        var out = Set<SplitRule>()
        for rule in rules {
            switch rule {
            case .domain:
                continue
            case .address(let a):
                if !covers(a, config: config) { out.insert(rule) }
            case .network(let n):
                let ok = config.peers.contains { peer in
                    peer.allowedIPs.contains { $0.prefixLength <= n.prefixLength && $0.contains(n.address) }
                }
                if !ok { out.insert(rule) }
            }
        }
        return out
    }

    /// AllowedIPs that are not default routes: routed automatically in split mode.
    public static func profileNetworks(_ config: TunnelConfig) -> [IPNetwork] {
        var seen = Set<IPNetwork>()
        var out: [IPNetwork] = []
        for peer in config.peers {
            for n in peer.allowedIPs where n.prefixLength > 0 && seen.insert(n).inserted { out.append(n) }
        }
        return out
    }
}
