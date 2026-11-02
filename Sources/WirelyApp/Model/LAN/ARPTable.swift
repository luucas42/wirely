import Foundation

/// Reads the output of `/usr/sbin/arp -an`.
enum ARPTable {
    /// Entries on `interface` that have a real unicast MAC.
    ///
    /// Lines look like `? (192.168.1.1) at a4:5e:60:0:0:1 on en0 ifscope [ethernet]`. Incomplete
    /// entries, broadcast and multicast hardware addresses and 224.0.0.0/4 destinations are dropped.
    static func parse(_ output: String, interface: String) -> [(ip: String, mac: MACAddress)] {
        var rows: [(ip: String, mac: MACAddress)] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let t = line.split(separator: " ")
            guard let open = t.firstIndex(where: { $0.hasPrefix("(") && $0.hasSuffix(")") }),
                  t.count > open + 4, t[open + 1] == "at", t[open + 3] == "on", t[open + 4] == interface else { continue }
            let ip = String(t[open].dropFirst().dropLast())
            let octets = ip.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
            guard octets.count == 4, !(224...239).contains(octets[0]),
                  let mac = MACAddress(String(t[open + 2])), !mac.isMulticast else { continue }
            rows.append((ip, mac))
        }
        return rows
    }
}
