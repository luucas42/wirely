import Foundation
import SystemConfiguration
import WirelyCore

/// Where the proxy sends names that don't match a rule.
public protocol NormalDNSSource {
    /// The DNS servers of the primary network service: its manual servers (from `backups`) if it has any,
    /// else the ones DHCP handed out. Never loopback.
    func normalUpstreams(backups: [DNSBackup]) -> [IPAddress]
}

public struct SystemDNSUpstreams: NormalDNSSource {
    public init() {}

    /// Manual servers win if any is usable (not loopback / unspecified), else DHCP's. Loopback is always
    /// dropped: it would be the proxy itself.
    public static func choose(manual: [String], dhcp: [String]) -> [IPAddress] {
        func usable(_ list: [String]) -> [IPAddress] {
            var seen = Set<IPAddress>()
            return list.compactMap { IPAddress($0) }.filter { !$0.isLoopbackOrUnspecified && seen.insert($0).inserted }
        }
        let m = usable(manual)
        return m.isEmpty ? usable(dhcp) : m
    }

    public func normalUpstreams(backups: [DNSBackup]) -> [IPAddress] {
        guard let store = SCDynamicStoreCreate(nil, "wirely.split-dns" as CFString, nil, nil) else { return [] }
        func value(_ key: String) -> [String: Any]? {
            SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        }
        guard let id = value("State:/Network/Global/IPv4")?["PrimaryService"] as? String else { return [] }
        let name = value("Setup:/Network/Service/\(id)")?["UserDefinedName"] as? String
        let manual = backups.first { $0.service == name }?.servers ?? []
        let dhcp = value("State:/Network/Service/\(id)/DNS")?["ServerAddresses"] as? [String] ?? []
        return SystemDNSUpstreams.choose(manual: manual, dhcp: dhcp)
    }
}
