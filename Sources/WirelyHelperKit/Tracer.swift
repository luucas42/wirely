import Foundation
import Darwin
import WirelyCore

/// Why a trace could not run. `code` is the stable error code the app localises.
public enum TraceError: Error, Equatable {
    case invalidTarget
    case resolve(String)
    case ipv6Unsupported
    case socket(String)
    case busy

    public var code: String {
        switch self {
        case .invalidTarget: return "trace.invalidTarget"
        case .resolve: return "trace.resolve"
        case .ipv6Unsupported: return "trace.ipv6Unsupported"
        case .socket: return "trace.socket"
        case .busy: return "trace.busy"
        }
    }

    /// Detail that goes with `code` (host name, system error text), when there is one.
    public var arg: String? {
        switch self {
        case .resolve(let s), .socket(let s): return s
        default: return nil
        }
    }
}

/// Parallel-TTL ICMP route tracer on a raw socket (needs root). One trace at a time.
public final class Tracer {
    private let lock = NSLock()

    public init() {}

    /// Trimmed target if it is a plausible host name or IPv4 literal; nothing else reaches the resolver.
    public static func validate(_ target: String) throws -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...253).contains(trimmed.utf8.count) else { throw TraceError.invalidTarget }
        if trimmed.contains(":") { throw TraceError.ipv6Unsupported }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else { throw TraceError.invalidTarget }
        return trimmed
    }

    /// First IPv4 address of `host` as dotted text and a ready `sockaddr_in`.
    private static func resolve(_ host: String) throws -> (String, sockaddr_in) {
        var literal = in_addr()
        if inet_pton(AF_INET, host, &literal) == 1 { return (host, makeAddr(literal)) }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, nil, &hints, &result) != 0 {
            var hints6 = addrinfo()
            hints6.ai_family = AF_INET6
            var result6: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(host, nil, &hints6, &result6) == 0 {
                freeaddrinfo(result6)
                throw TraceError.ipv6Unsupported
            }
            throw TraceError.resolve(host)
        }
        defer { freeaddrinfo(result) }
        guard let info = result, let sa = info.pointee.ai_addr, info.pointee.ai_family == AF_INET else {
            throw TraceError.resolve(host)
        }
        let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        return (dotted(addr.sin_addr), makeAddr(addr.sin_addr))
    }

    private static func makeAddr(_ a: in_addr) -> sockaddr_in {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_addr = a
        return sin
    }

    private static func dotted(_ a: in_addr) -> String {
        var a = a
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    /// Traces the route to `target`. `deadline` is the overall time budget in seconds.
    public func trace(_ target: String, deadline: TimeInterval = 1.5) throws -> TraceResult {
        guard lock.try() else { throw TraceError.busy }
        defer { lock.unlock() }

        let host = try Self.validate(target)
        let (address, destination) = try Self.resolve(host)

        let fd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)
        guard fd >= 0 else { throw TraceError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }

        let id = UInt16.random(in: 0...UInt16.max)
        let payload = [UInt8](repeating: 0x57, count: 24)
        var collector = TraceCollector()
        let start = ProcessInfo.processInfo.systemUptime
        let end = start + deadline
        let retryAt = start + 0.15

        func probe(ttl: Int, round: Int) throws {
            var value = Int32(ttl)
            guard setsockopt(fd, IPPROTO_IP, IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw TraceError.socket(String(cString: strerror(errno)))
            }
            let packet = ICMPCodec.echoRequest(id: id, seq: TraceCollector.seq(ttl: ttl, round: round),
                                               payload: payload)
            var to = destination
            let sent = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &to) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            // A failed send (e.g. no route yet) just leaves that TTL unanswered; only the first probe's
            // setup errors are fatal.
            if sent >= 0 { collector.sent(ttl: ttl, round: round, at: ProcessInfo.processInfo.systemUptime) }
        }

        for ttl in 1...collector.maxTTL { try probe(ttl: ttl, round: 0) }

        var secondRoundSent = false
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= end { break }
            if !secondRoundSent && now >= retryAt {
                secondRoundSent = true
                for ttl in collector.unansweredTTLs() { try probe(ttl: ttl, round: 1) }
                continue
            }
            if collector.isComplete() && (secondRoundSent || collector.unansweredTTLs().isEmpty) { break }

            // Wait for data, but wake in time to send round 1.
            let wakeAt = secondRoundSent ? end : min(end, retryAt)
            let waitMs = max(1, Int32(((wakeAt - now) * 1000).rounded(.up)))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, waitMs)
            if ready < 0 {
                if errno == EINTR { continue }
                throw TraceError.socket(String(cString: strerror(errno)))
            }
            guard ready > 0 else { continue }
            let n = recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
            guard n > 0 else { continue }
            if let answer = ICMPCodec.parse(Array(buffer[0..<n]), id: id) {
                collector.received(answer, at: ProcessInfo.processInfo.systemUptime, target: address)
            }
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - start
        return TraceResult(target: host, address: address, hops: collector.hops(),
                           durationMs: Int((elapsed * 1000).rounded()), reached: collector.reached)
    }
}
