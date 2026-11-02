import Foundation

/// The local network the Mac is on: its interface, address, router and display name.
struct NetworkInfo: Equatable {
    /// BSD interface name, e.g. `en0`.
    var interface: String
    /// What to show: the Wi-Fi name, else the network service's name ("Wi-Fi", "Ethernet").
    var name: String
    /// This Mac's IPv4 address on the interface.
    var address: String
    /// Prefix length of the interface's subnet.
    var prefix: Int
    var router: String?
    var isWiFi: Bool
}

/// A 48-bit hardware address. Parses both padded (`a4:5e:60:00:00:01`) and unpadded (`a:b:c:d:e:f`, as `arp` prints it) forms.
struct MACAddress: Hashable, Codable, CustomStringConvertible {
    let bytes: [UInt8]

    init?(_ string: String) {
        let parts = string.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var out: [UInt8] = []
        for part in parts {
            guard (1...2).contains(part.count), part.allSatisfy(\.isHexDigit), let b = UInt8(part, radix: 16) else { return nil }
            out.append(b)
        }
        bytes = out
    }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let mac = MACAddress(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad MAC address"))
        }
        self = mac
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    /// Lowercase, zero-padded, colon-separated.
    var description: String { bytes.map { String(format: "%02x", $0) }.joined(separator: ":") }

    /// The manufacturer prefix (first three bytes) as six uppercase hex digits, the key of the OUI table.
    var oui: String { bytes.prefix(3).map { String(format: "%02X", $0) }.joined() }

    /// Bit 0x02 of the first byte: a randomised ("private") address, as phones use per network.
    var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }

    /// Bit 0x01 of the first byte: a group address, never a single device.
    var isMulticast: Bool { bytes[0] & 0x01 != 0 }

    var isBroadcast: Bool { bytes.allSatisfy { $0 == 0xFF } }
}

/// What a device looks like to the user; picks the map icon.
enum DeviceKind: String, Codable, CaseIterable {
    case router, computer, phone, tablet, watch, tv, speaker, printer, smartHome, console, nas, unknown

    /// SF Symbol for the map and the list.
    var symbol: String {
        switch self {
        case .router: return "wifi.router"
        case .computer: return "laptopcomputer"
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .watch: return "applewatch"
        case .tv: return "tv"
        case .speaker: return "hifispeaker"
        case .printer: return "printer"
        case .smartHome: return "lightbulb"
        case .console: return "gamecontroller"
        case .nas: return "externaldrive"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// One device found on the network. Identified by its MAC.
struct LANDevice: Identifiable, Equatable {
    var ip: String
    var mac: MACAddress
    var name: String
    var kind: DeviceKind
    /// Short manufacturer name; nil for an unknown or randomised address.
    var vendor: String? = nil
    /// Model identifier from Bonjour `_device-info` (e.g. `MacBookPro18,3`).
    var model: String? = nil
    var isRouter = false
    var isThisMac = false
    /// Joined after the first scan of this network and not yet looked at.
    var isNew = false
    var firstSeen: Date? = nil
    var lastSeen: Date? = nil
    /// Result of the on-demand port check; nil until it has been run.
    var openPorts: [Int]? = nil

    var id: MACAddress { mac }
}
