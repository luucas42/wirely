import Foundation
import Darwin

/// Host names for local addresses, asked from the router only. Nothing goes to the system's resolvers: while a
/// tunnel is up those are the VPN's DNS servers on the internet, and they cannot answer for 192.168.x.x anyway.
enum ReverseDNS {
    /// The host name only: a router answers with the device's DHCP name plus its own domain
    /// ("Kitchen-Plug.lan"), so everything after the first dot is dropped. Nil when nothing is left or
    /// the name is just the address.
    static func clean(_ name: String, ip: String) -> String? {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.hasSuffix(".") { n.removeLast() }
        if n == ip { return nil }
        let first = n.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return first.isEmpty ? nil : first
    }

    // MARK: Packets

    /// A standard DNS query (RD=1, one question) for the PTR record of an IPv4 address; nil for anything else.
    static func ptrQuery(id: UInt16, ip: String) -> [UInt8]? {
        let o = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard o.count == 4, o.allSatisfy({ UInt8($0) != nil }) else { return nil }
        var p: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in o.reversed() + ["in-addr", "arpa"] {
            p.append(UInt8(label.utf8.count))
            p.append(contentsOf: Array(label.utf8))
        }
        p.append(contentsOf: [0, 0, 12, 0, 1])
        return p
    }

    /// The ID and the first PTR answer's name of a successful response; nil for anything else
    /// (garbage, truncation, errors, no PTR answer, pointer loops, reads out of bounds).
    static func parsePTRResponse(_ b: [UInt8]) -> (id: UInt16, name: String)? {
        guard b.count >= 12, b[2] & 0x80 != 0, b[3] & 0x0F == 0 else { return nil }
        let id = UInt16(b[0]) << 8 | UInt16(b[1])
        let questions = Int(b[4]) << 8 | Int(b[5])
        let answers = Int(b[6]) << 8 | Int(b[7])
        var pos = 12
        for _ in 0..<questions {
            guard let (_, next) = readName(b, at: pos), next + 4 <= b.count else { return nil }
            pos = next + 4
        }
        for _ in 0..<answers {
            guard let (_, next) = readName(b, at: pos), next + 10 <= b.count else { return nil }
            let type = Int(b[next]) << 8 | Int(b[next + 1])
            let length = Int(b[next + 8]) << 8 | Int(b[next + 9])
            let data = next + 10
            guard data + length <= b.count else { return nil }
            if type == 12 {
                guard let (name, _) = readName(b, at: data), !name.isEmpty else { return nil }
                return (id, name)
            }
            pos = data + length
        }
        return nil
    }

    /// A possibly compressed name at `start`, and the offset just after it in the original position.
    private static func readName(_ b: [UInt8], at start: Int) -> (name: String, next: Int)? {
        var labels: [String] = []
        var pos = start
        var next: Int?
        var jumps = 0
        var total = 0
        while true {
            guard pos < b.count else { return nil }
            let len = Int(b[pos])
            if len == 0 {
                return (labels.joined(separator: "."), next ?? pos + 1)
            } else if len & 0xC0 == 0xC0 {
                guard pos + 1 < b.count else { return nil }
                jumps += 1
                guard jumps <= 16 else { return nil }
                if next == nil { next = pos + 2 }
                pos = (len & 0x3F) << 8 | Int(b[pos + 1])
            } else if len & 0xC0 == 0 {
                guard pos + 1 + len <= b.count else { return nil }
                total += len + 1
                guard total <= 255 else { return nil }
                labels.append(String(decoding: b[(pos + 1)..<(pos + 1 + len)], as: UTF8.self))
                pos += 1 + len
            } else {
                return nil
            }
        }
    }

    // MARK: Lookup

    /// Names for `ips` from the router (port 53, out of `interface`), whatever arrived within `budget` seconds.
    /// With no router there is nobody to ask: the result is empty.
    static func names(for ips: [String], router: String?, interface: String?, budget: Double = 1.0) async -> [String: String] {
        guard let router, !ips.isEmpty else { return [:] }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: ask(router: router, interface: interface, ips: ips, budget: budget))
            }
        }
    }

    private static func ask(router: String, interface: String?, ips: [String], budget: Double) -> [String: String] {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, router, &sa.sin_addr) == 1 else { return [:] }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        if let interface {
            var index = if_nametoindex(interface)
            if index != 0 { setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) }
        }
        // A connected socket only receives datagrams from the router.
        let connected = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return [:] }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var pending: [UInt16: String] = [:]
        for ip in ips {
            var id = UInt16.random(in: 0...UInt16.max)
            while pending[id] != nil { id = UInt16.random(in: 0...UInt16.max) }
            guard let q = ptrQuery(id: id, ip: ip) else { continue }
            pending[id] = ip
            _ = send(fd, q, q.count, 0)
        }

        var result: [String: String] = [:]
        var buffer = [UInt8](repeating: 0, count: 1500)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(budget * 1_000_000_000)
        while !pending.isEmpty {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32((deadline - now) / 1_000_000) + 1) > 0 else { break }
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { continue }
            if let r = parsePTRResponse(Array(buffer[0..<n])), let ip = pending.removeValue(forKey: r.id),
               let name = clean(r.name, ip: ip) {
                result[ip] = name
            }
        }
        return result
    }
}
