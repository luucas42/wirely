import Foundation
import SystemConfiguration
import WirelyCore

public struct DNSConfigError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// `DNSConfigurator` on the SystemConfiguration preferences API — what `networksetup` uses
/// internally, but every service is read and written in a single open/commit/apply instead of
/// one process per call (~20 calls and ~1.4 s per connect).
public final class SystemDNSConfigurator: DNSConfigurator {
    public init() {}

    public func snapshot() throws -> [DNSBackup] {
        try withPreferences(lock: false) { prefs in
            try hardwareServices(prefs).map { service in
                let config = dnsConfiguration(service)
                return DNSBackup(service: SCNetworkServiceGetName(service) as String? ?? "",
                                 servers: config[kSCPropNetDNSServerAddresses as String] as? [String] ?? [],
                                 searchDomains: config[kSCPropNetDNSSearchDomains as String] as? [String] ?? [])
            }
        }
    }

    public func apply(_ settings: [DNSBackup]) throws {
        guard !settings.isEmpty else { return }
        try withPreferences(lock: true) { prefs in
            let byName = Dictionary(try hardwareServices(prefs).compactMap { s -> (String, SCNetworkService)? in
                guard let name = SCNetworkServiceGetName(s) as String? else { return nil }
                return (name, s)
            }, uniquingKeysWith: { first, _ in first })
            var missing: [String] = []
            for setting in settings {
                guard let service = byName[setting.service] else { missing.append(setting.service); continue }
                guard let proto = dnsProtocol(service, create: true) else {
                    throw DNSConfigError(message: "DNS protocol unavailable for \(setting.service)")
                }
                // Only touch the two keys networksetup manages; keep anything else in the dictionary.
                var config = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                set(&config, kSCPropNetDNSServerAddresses as String, setting.servers)
                set(&config, kSCPropNetDNSSearchDomains as String, setting.searchDomains)
                guard SCNetworkProtocolSetConfiguration(proto, config as CFDictionary) else {
                    throw DNSConfigError(message: "set DNS on \(setting.service): \(lastError())")
                }
            }
            guard SCPreferencesCommitChanges(prefs) else { throw DNSConfigError(message: "commit: \(lastError())") }
            guard SCPreferencesApplyChanges(prefs) else { throw DNSConfigError(message: "apply: \(lastError())") }
            if !missing.isEmpty {
                throw DNSConfigError(message: "services no longer present: \(missing.joined(separator: ", "))")
            }
        }
    }

    // MARK: - Helpers

    private func withPreferences<T>(lock: Bool, _ body: (SCPreferences) throws -> T) throws -> T {
        guard let prefs = SCPreferencesCreate(nil, "Wirely" as CFString, nil) else {
            throw DNSConfigError(message: "network preferences: \(lastError())")
        }
        guard lock else { return try body(prefs) }
        // Never block: System Settings holding the lock must not stall the helper's queue.
        var locked = false
        for _ in 0..<10 {
            if SCPreferencesLock(prefs, false) { locked = true; break }
            usleep(50_000)
        }
        guard locked else { throw DNSConfigError(message: "network preferences are locked by another app") }
        defer { SCPreferencesUnlock(prefs) }
        return try body(prefs)
    }

    /// Enabled services with a BSD device that appear in the current set's service order — the same
    /// list `networksetup -listnetworkserviceorder` shows (hidden per-port services are left alone).
    private func hardwareServices(_ prefs: SCPreferences) throws -> [SCNetworkService] {
        guard let set = SCNetworkSetCopyCurrent(prefs),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            throw DNSConfigError(message: "no current network set: \(lastError())")
        }
        let order = (SCNetworkSetGetServiceOrder(set) as? [String]) ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        func position(_ s: SCNetworkService) -> Int? { (SCNetworkServiceGetServiceID(s) as String?).flatMap { rank[$0] } }
        // macOS keeps placeholder services for some ports (e.g. "Ethernet Adapter (en4)") marked
        // HiddenConfiguration; networksetup and System Settings don't list them, so neither do we.
        func hidden(_ s: SCNetworkService) -> Bool {
            guard let id = SCNetworkServiceGetServiceID(s) as String?,
                  let iface = SCPreferencesPathGetValue(prefs, "/NetworkServices/\(id)/Interface" as CFString)
                    as? [String: Any] else { return false }
            return iface["HiddenConfiguration"] as? Bool == true
        }
        return services
            .filter { s in
                guard position(s) != nil, !hidden(s), SCNetworkServiceGetEnabled(s),
                      let iface = SCNetworkServiceGetInterface(s) else { return false }
                return SCNetworkInterfaceGetBSDName(iface) != nil
            }
            .sorted { (position($0) ?? Int.max) < (position($1) ?? Int.max) }
    }

    private func dnsProtocol(_ service: SCNetworkService, create: Bool) -> SCNetworkProtocol? {
        if let p = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) { return p }
        guard create, SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeDNS),
              let p = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else { return nil }
        _ = SCNetworkProtocolSetEnabled(p, true)
        return p
    }

    private func dnsConfiguration(_ service: SCNetworkService) -> [String: Any] {
        guard let p = dnsProtocol(service, create: false) else { return [:] }
        return SCNetworkProtocolGetConfiguration(p) as? [String: Any] ?? [:]
    }

    private func set(_ config: inout [String: Any], _ key: String, _ values: [String]) {
        if values.isEmpty { config.removeValue(forKey: key) } else { config[key] = values }
    }

    private func lastError() -> String {
        String(cString: SCErrorString(SCError()))
    }
}
