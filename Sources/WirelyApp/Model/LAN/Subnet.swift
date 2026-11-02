import Foundation

/// Which addresses to probe.
enum Subnet {
    /// Every host address worth probing around `address`, except `address` itself.
    ///
    /// Subnets larger than /24 are capped to the /24 that contains `address`. Network and broadcast
    /// addresses are skipped; /31 and /32 have nothing to scan and give an empty list.
    static func hosts(address: String, prefix: Int) -> [String] {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard octets.count == 4, (0...32).contains(prefix) else { return [] }
        let effective = max(prefix, 24)
        guard effective <= 30 else { return [] }
        let own = octets.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let mask = ~UInt32(0) << UInt32(32 - effective)
        let network = own & mask
        let broadcast = network | ~mask
        return ((network + 1)..<broadcast).filter { $0 != own }.map {
            "\($0 >> 24).\($0 >> 16 & 0xFF).\($0 >> 8 & 0xFF).\($0 & 0xFF)"
        }
    }
}
