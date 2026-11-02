import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN

/// Reads the Mac's current local network from the system configuration store. Never asks for Location.
enum NetworkProbe {
    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "gif"]

    static func isTunnel(_ interface: String) -> Bool {
        tunnelPrefixes.contains { interface.hasPrefix($0) }
    }

    /// Prefix length of a dotted-quad mask (`255.255.255.0` is 24); nil for a non-contiguous or malformed mask.
    static func prefixLength(mask: String) -> Int? {
        let o = mask.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard o.count == 4 else { return nil }
        let bits = o.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let n = bits.nonzeroBitCount
        return bits == (n == 0 ? 0 : ~UInt32(0) << UInt32(32 - n)) ? n : nil
    }

    /// The network of the primary physical interface. When a VPN tunnel holds the default route, the first
    /// non-tunnel service in the service order that has an address and a router is used instead.
    static func current() -> NetworkInfo? {
        guard let store = SCDynamicStoreCreate(nil, "Wirely" as CFString, nil, nil) else { return nil }
        func dict(_ key: String) -> [String: Any]? { SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] }

        var interface: String?
        var service: String?
        var router: String?
        if let g = dict("State:/Network/Global/IPv4"), let i = g["PrimaryInterface"] as? String, !isTunnel(i) {
            interface = i
            service = g["PrimaryService"] as? String
            router = g["Router"] as? String
        } else {
            let order = (dict("Setup:/Network/Global/IPv4")?["ServiceOrder"] as? [String]) ?? []
            for id in order {
                guard let v4 = dict("State:/Network/Service/\(id)/IPv4"),
                      let i = v4["InterfaceName"] as? String, !isTunnel(i),
                      (v4["Addresses"] as? [String])?.first != nil, let r = v4["Router"] as? String else { continue }
                interface = i; service = id; router = r
                break
            }
        }
        guard let interface, let v4 = dict("State:/Network/Interface/\(interface)/IPv4"),
              let address = (v4["Addresses"] as? [String])?.first,
              let mask = (v4["SubnetMasks"] as? [String])?.first, let prefix = prefixLength(mask: mask) else { return nil }

        let wifi = CWWiFiClient.shared()
        let isWiFi = wifi.interfaceNames()?.contains(interface) ?? false
        var name = isWiFi ? wifi.interface(withName: interface)?.ssid() : nil   // nil without Location permission: fine
        if name == nil, let service { name = dict("Setup:/Network/Service/\(service)")?["UserDefinedName"] as? String }
        return NetworkInfo(interface: interface, name: name ?? (isWiFi ? "Wi-Fi" : "Ethernet"), address: address,
                           prefix: prefix, router: router, isWiFi: isWiFi)
    }

    /// The hardware address of an interface (`en0`).
    static func interfaceMAC(_ bsdName: String) -> MACAddress? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: p.pointee.ifa_name) == bsdName, let addr = p.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let sdl = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_dl.self)
            guard sdl.pointee.sdl_alen == 6, let off = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else { continue }
            let bytes = UnsafeRawPointer(sdl).advanced(by: off + Int(sdl.pointee.sdl_nlen)).assumingMemoryBound(to: UInt8.self)
            return MACAddress((0..<6).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":"))
        }
        return nil
    }

    static func computerName() -> String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }
}
