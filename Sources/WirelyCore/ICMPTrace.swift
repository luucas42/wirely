import Foundation

/// A reply that belongs to one of our probes.
public struct ICMPAnswer: Equatable {
    public enum Kind: Equatable { case echoReply, timeExceeded, unreachable }
    public var kind: Kind
    /// Dotted IPv4 source of the outer IP header: the router (or target) that answered.
    public var from: String
    /// Sequence number of the probe this answers.
    public var seq: UInt16
    public init(kind: Kind, from: String, seq: UInt16) {
        self.kind = kind
        self.from = from
        self.seq = seq
    }
}

/// What a trace probe looks like on the wire.
public enum ProbeKind: Equatable {
    case icmpEcho
    /// UDP datagrams from `sourcePort` to `basePort + seq`, as classic traceroute sends them.
    case udp(sourcePort: UInt16, basePort: UInt16)
}

/// ICMP Echo encoding and parsing for route tracing. Pure bytes, no sockets.
public enum ICMPCodec {
    /// RFC 1071 Internet checksum.
    public static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// An ICMP Echo Request (type 8, code 0) with a valid checksum.
    public static func echoRequest(id: UInt16, seq: UInt16, payload: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0, UInt8(id >> 8), UInt8(id & 0xff), UInt8(seq >> 8), UInt8(seq & 0xff)]
        packet += payload
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)
        return packet
    }

    /// Reads what a macOS raw ICMP socket returns: the full IPv4 header (IHL in the low nibble of byte 0)
    /// followed by the ICMP message. Returns nil for other identifiers, other ICMP types, or short/malformed input.
    public static func parse(_ packet: [UInt8], id: UInt16) -> ICMPAnswer? {
        guard let outer = ipv4HeaderLength(packet, minimumPayload: 8), packet[9] == 1 else { return nil }
        let from = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
        let type = packet[outer], code = packet[outer + 1]
        switch type {
        case 0:
            guard be16(packet, outer + 4) == id else { return nil }
            return ICMPAnswer(kind: .echoReply, from: from, seq: be16(packet, outer + 6))
        case 11, 3:
            if type == 11 && code != 0 { return nil }
            // 8 bytes of ICMP header, then the quoted original IPv4 header and the first 8 bytes of our echo.
            let quoted = Array(packet[(outer + 8)...])
            guard let inner = ipv4HeaderLength(quoted, minimumPayload: 8), quoted[9] == 1,
                  quoted[inner] == 8, quoted[inner + 1] == 0,
                  be16(quoted, inner + 4) == id else { return nil }
            return ICMPAnswer(kind: type == 11 ? .timeExceeded : .unreachable, from: from,
                              seq: be16(quoted, inner + 6))
        default:
            return nil
        }
    }

    /// Like `parse(_:id:)` for any probe kind. UDP probes are recognised by the quoted UDP source port; the
    /// answer's `seq` is the probe's destination port minus `basePort`. A Port Unreachable from the target
    /// comes back as `.unreachable`.
    public static func parse(_ packet: [UInt8], probe: ProbeKind, icmpID: UInt16) -> ICMPAnswer? {
        switch probe {
        case .icmpEcho:
            return parse(packet, id: icmpID)
        case .udp(let sourcePort, let basePort):
            guard let outer = ipv4HeaderLength(packet, minimumPayload: 8), packet[9] == 1 else { return nil }
            let type = packet[outer], code = packet[outer + 1]
            guard type == 11 && code == 0 || type == 3 else { return nil }
            let quoted = Array(packet[(outer + 8)...])
            guard let inner = ipv4HeaderLength(quoted, minimumPayload: 8), quoted[9] == 17,
                  be16(quoted, inner) == sourcePort else { return nil }
            let destinationPort = be16(quoted, inner + 2)
            guard destinationPort >= basePort else { return nil }
            let from = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
            return ICMPAnswer(kind: type == 11 ? .timeExceeded : .unreachable, from: from,
                              seq: destinationPort - basePort)
        }
    }

    /// Header length of the IPv4 packet at the start of `bytes`, if it is IPv4 and leaves `minimumPayload` bytes.
    private static func ipv4HeaderLength(_ bytes: [UInt8], minimumPayload: Int) -> Int? {
        guard bytes.count >= 20, bytes[0] >> 4 == 4 else { return nil }
        let length = Int(bytes[0] & 0x0f) * 4
        guard length >= 20, bytes.count >= length + minimumPayload else { return nil }
        return length
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
}

/// Collects the answers to parallel TTL probes (mtr-style) and turns them into hops. Pure state: times are
/// passed in, so it has no clock. The probe sequence number encodes `round * 64 + ttl`; for UDP probes it is
/// the destination port minus `udpBasePort`.
public struct TraceCollector {
    public let maxTTL: Int
    private var sentAt: [UInt16: TimeInterval] = [:]
    private var answers: [Int: (address: String, rttMs: Double, isDestination: Bool)] = [:]
    private var answeredSeqs: Set<UInt16> = []

    public init(maxTTL: Int = 30) {
        self.maxTTL = maxTTL
    }

    /// First destination port of a UDP probe; the probe's sequence number is added to it.
    public static let udpBasePort: UInt16 = 33434

    /// Sequence number carried by the probe for `ttl` in `round`.
    public static func seq(ttl: Int, round: Int) -> UInt16 { UInt16(round * 64 + ttl) }

    public mutating func sent(ttl: Int, round: Int, at: TimeInterval) {
        sentAt[Self.seq(ttl: ttl, round: round)] = at
    }

    /// Returns true when the answer is news: the first one for its TTL (at or before the destination), or one
    /// that sets or lowers the destination TTL.
    @discardableResult
    public mutating func received(_ a: ICMPAnswer, at: TimeInterval, target: String) -> Bool {
        let ttl = Int(a.seq) % 64
        guard (1...maxTTL).contains(ttl), let start = sentAt[a.seq] else { return false }
        let first = answers[ttl] == nil
        let destinationBefore = destinationTTL
        answeredSeqs.insert(a.seq)
        let rtt = max(0, (at - start) * 1000)
        let isDestination = (a.kind == .echoReply || a.kind == .unreachable) && a.from == target
        if let old = answers[ttl] {
            // Keep the first router seen, the fastest round trip, and any proof that this is the destination.
            answers[ttl] = (old.address, min(old.rttMs, rtt), old.isDestination || isDestination)
        } else {
            answers[ttl] = (a.from, rtt, isDestination)
        }
        let destinationAfter = destinationTTL
        if let destinationAfter, destinationAfter != destinationBefore { return true }
        return first && ttl <= (destinationAfter ?? maxTTL)
    }

    /// Smallest TTL whose answer came from the target, across all rounds.
    public var destinationTTL: Int? {
        answers.filter { $0.value.isDestination }.keys.min()
    }

    /// Largest TTL that has an answer.
    public var lastAnsweredTTL: Int? { answers.keys.max() }

    /// TTLs that have an answer from any round.
    public var answeredTTLs: Set<Int> { Set(answers.keys) }

    /// TTLs that got an answer to their probe in `round`.
    public func answered(inRound round: Int) -> Set<Int> {
        Set(answeredSeqs.filter { Int($0) / 64 == round }.map { Int($0) % 64 })
    }

    /// The target answered and every TTL up to it has an answer.
    public func isComplete() -> Bool {
        guard let dest = destinationTTL else { return false }
        return (1...dest).allSatisfy { answers[$0] != nil }
    }

    /// TTLs worth probing again: no answer yet, up to the destination (or `maxTTL` while it is unknown).
    public func unansweredTTLs() -> [Int] {
        (1...(destinationTTL ?? maxTTL)).filter { answers[$0] == nil }
    }

    /// Some hop is the destination.
    public var reached: Bool { destinationTTL != nil }

    /// Hops up to the destination, or up to the last answer when the target never answered.
    public func hops() -> [TraceHop] {
        guard let last = destinationTTL ?? answers.keys.max() else { return [] }
        return (1...last).map { ttl in
            let a = answers[ttl]
            return TraceHop(ttl: ttl, address: a?.address, rttMs: a?.rttMs, isDestination: ttl == destinationTTL)
        }
    }
}
