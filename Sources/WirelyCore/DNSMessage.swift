import Foundation

/// Minimal RFC 1035 codec: just enough for the split-tunnel DNS proxy. Every function is bounds-checked
/// and returns nil / empty on malformed input.
public enum DNSMessage {
    public static let typeA: UInt16 = 1
    public static let typeAAAA: UInt16 = 28
    public static let typeHTTPS: UInt16 = 65
    static let maxJumps = 16
    static let headerSize = 12

    /// Reads a (possibly compressed) name at `start`. Returns the dotted lowercase name without a trailing
    /// dot, the offset just after the name in place, and whether a compression pointer was used.
    static func readName(_ b: [UInt8], at start: Int) -> (name: String, next: Int, jumped: Bool)? {
        var pos = start
        var next = -1
        var jumps = 0
        var labels: [String] = []
        var total = 0
        while true {
            guard pos >= 0, pos < b.count else { return nil }
            let len = Int(b[pos])
            if len == 0 {
                if next < 0 { next = pos + 1 }
                return (labels.joined(separator: ".").lowercased(), next, jumps > 0)
            }
            switch len & 0xC0 {
            case 0xC0:
                guard pos + 1 < b.count else { return nil }
                if next < 0 { next = pos + 2 }
                jumps += 1
                guard jumps <= maxJumps else { return nil }
                pos = (len & 0x3F) << 8 | Int(b[pos + 1])
            case 0:
                guard pos + 1 + len <= b.count else { return nil }
                total += len + 1
                guard total <= 255 else { return nil }
                labels.append(String(decoding: b[(pos + 1)..<(pos + 1 + len)], as: UTF8.self))
                pos += 1 + len
            default:
                return nil
            }
        }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }

    /// The first question of a query (QR = 0).
    public static func parseQuery(_ bytes: [UInt8]) -> (id: UInt16, name: String, type: UInt16)? {
        guard bytes.count >= headerSize, bytes[2] & 0x80 == 0, u16(bytes, 4) >= 1,
              let n = readName(bytes, at: headerSize), n.next + 4 <= bytes.count else { return nil }
        return (UInt16(u16(bytes, 0)), n.name, UInt16(u16(bytes, n.next)))
    }

    /// A and AAAA records of the answer section, in order. Empty for anything malformed.
    public static func answerAddresses(_ response: [UInt8]) -> [IPAddress] {
        guard response.count >= headerSize else { return [] }
        let qd = u16(response, 4), an = u16(response, 6)
        var pos = headerSize
        for _ in 0..<qd {
            guard let n = readName(response, at: pos), n.next + 4 <= response.count else { return [] }
            pos = n.next + 4
        }
        var out: [IPAddress] = []
        for _ in 0..<an {
            guard let n = readName(response, at: pos), n.next + 10 <= response.count else { return [] }
            let type = u16(response, n.next)
            let rdlen = u16(response, n.next + 8)
            let rdata = n.next + 10
            guard rdata + rdlen <= response.count else { return [] }
            let data = Array(response[rdata..<(rdata + rdlen)])
            if type == Int(typeA), rdlen == 4, let ip = IPAddress(data.map(String.init).joined(separator: ".")) {
                out.append(ip)
            } else if type == Int(typeAAAA), rdlen == 16 {
                let text = stride(from: 0, to: 16, by: 2)
                    .map { String(format: "%x", Int(data[$0]) << 8 | Int(data[$0 + 1])) }.joined(separator: ":")
                if let ip = IPAddress(text) { out.append(ip) }
            }
            pos = rdata + rdlen
        }
        return out
    }

    /// Header + the query's first question, with the given RCODE and no records.
    private static func reply(to query: [UInt8], rcode: UInt8) -> [UInt8]? {
        guard query.count >= headerSize, query[2] & 0x80 == 0, u16(query, 4) >= 1,
              let n = readName(query, at: headerSize), !n.jumped, n.next + 4 <= query.count else { return nil }
        var out = Array(query[0..<(n.next + 4)])
        out[2] = 0x80 | (query[2] & 0x79)            // QR = 1, opcode and RD copied, AA/TC cleared
        out[3] = 0x80 | rcode                          // RA = 1, Z/AD/CD cleared
        out[4] = 0; out[5] = 1                         // QDCOUNT = 1
        for i in 6..<12 { out[i] = 0 }                 // AN/NS/AR = 0
        return out
    }

    /// NOERROR with no answers: tells an app "no such record type" so it falls back.
    public static func emptyResponse(to query: [UInt8]) -> [UInt8]? { reply(to: query, rcode: 0) }

    public static func servfail(to query: [UInt8]) -> [UInt8]? { reply(to: query, rcode: 2) }
}
