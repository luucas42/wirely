import Testing
import Foundation
import Darwin
@testable import WirelyHelperKit
@testable import WirelyCore

// MARK: fake upstream

/// UDP + TCP DNS server on an ephemeral 127.0.0.1 port that answers with whatever `handler` returns.
private final class FakeDNS {
    struct Reply {
        var bytes: [UInt8]?
        var delay: TimeInterval = 0
    }
    typealias Hit = (name: String, type: UInt16, tcp: Bool)

    let port: UInt16
    var handler: (_ query: [UInt8], _ tcp: Bool) -> Reply
    private let lock = NSLock()
    private var stopped = false
    private var recorded: [Hit] = []
    private let udp: Int32
    private let tcp: Int32
    private let group = DispatchGroup()

    var hits: [Hit] { lock.lock(); defer { lock.unlock() }; return recorded }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    init(handler: @escaping (_ query: [UInt8], _ tcp: Bool) -> Reply) throws {
        self.handler = handler
        var chosen: (Int32, Int32, UInt16)?
        for _ in 0..<10 where chosen == nil {
            let u = try bindSocket(SOCK_DGRAM, port: 0)
            let p = localPort(of: u)
            if let t = try? bindSocket(SOCK_STREAM, port: p) {
                listen(t, 16)
                chosen = (u, t, p)
            } else {
                close(u)
            }
        }
        guard let c = chosen else { throw SplitDNSError.portInUse }
        (udp, tcp, port) = c
        group.enter()
        Thread.detachNewThread { [self] in defer { group.leave() }; udpLoop() }
        group.enter()
        Thread.detachNewThread { [self] in defer { group.leave() }; tcpLoop() }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        group.wait()
        close(udp); close(tcp)
    }

    private func handle(_ query: [UInt8], tcp: Bool) -> Reply? {
        guard let q = DNSMessage.parseQuery(query) else { return nil }
        lock.lock(); recorded.append((q.name, q.type, tcp)); lock.unlock()
        return handler(query, tcp)
    }

    private func udpLoop() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while !isStopped {
            var pfd = pollfd(fd: udp, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            var from = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udp, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let query = Array(buf[0..<n])
            let (client, clientLen) = (from, len)
            group.enter()
            Thread.detachNewThread { [self] in
                defer { group.leave() }
                guard let r = handle(query, tcp: false), let bytes = r.bytes else { return }
                sleepUnlessStopped(r.delay)
                var dest = client
                _ = withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(udp, bytes, bytes.count, 0, $0, clientLen) }
                }
            }
        }
    }

    private func tcpLoop() {
        while !isStopped {
            var pfd = pollfd(fd: tcp, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            let conn = accept(tcp, nil, nil)
            guard conn >= 0 else { continue }
            group.enter()
            Thread.detachNewThread { [self] in
                defer { group.leave(); close(conn) }
                while !isStopped, let head = recvExactly(conn, 2, timeout: 1) {
                    guard let query = recvExactly(conn, Int(head[0]) << 8 | Int(head[1]), timeout: 1),
                          let r = handle(query, tcp: true), let bytes = r.bytes else { return }
                    sleepUnlessStopped(r.delay)
                    _ = sendAll(conn, [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes)
                }
            }
        }
    }

    private func sleepUnlessStopped(_ t: TimeInterval) {
        let end = Date().addingTimeInterval(t)
        while Date() < end && !isStopped { Thread.sleep(forTimeInterval: 0.02) }
    }

    var upstream: DNSUpstream { DNSUpstream(address: IPAddress("127.0.0.1")!, port: port) }
}

private func bindSocket(_ type: Int32, port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, type, 0)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    sin.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &sin) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard rc == 0 else { close(fd); throw SplitDNSError.portInUse }
    return fd
}

private func localPort(of fd: Int32) -> UInt16 {
    var sin = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &sin) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return UInt16(bigEndian: sin.sin_port)
}

private func recvExactly(_ fd: Int32, _ n: Int, timeout: TimeInterval) -> [UInt8]? {
    var out = [UInt8](repeating: 0, count: n)
    var got = 0
    let end = Date().addingTimeInterval(timeout)
    while got < n {
        let left = end.timeIntervalSinceNow
        guard left > 0 else { return nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(left * 1000) + 1) > 0 else { return nil }
        let r = out.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
        guard r > 0 else { return nil }
        got += r
    }
    return out
}

private func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var sent = 0
    while sent < bytes.count {
        let r = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
        guard r > 0 else { return false }
        sent += r
    }
    return true
}

// MARK: canned packets and clients

private func questionEnd(_ q: [UInt8]) -> Int {
    var i = 12
    while q[i] != 0 { i += Int(q[i]) + 1 }
    return i + 1 + 4
}

private func canned(_ query: [UInt8], _ addresses: [String] = [], tc: Bool = false) -> [UInt8] {
    let id = query[0..<2]
    var out = Array(id) + [UInt8(tc ? 0x83 : 0x81), 0x80, 0, 1, 0, UInt8(addresses.count), 0, 0, 0, 0]
    out += query[12..<questionEnd(query)]
    for a in addresses {
        let bytes = IPAddress(a)!.bytes
        out += [0xC0, 0x0C, 0, bytes.count == 4 ? 1 : 28, 0, 1, 0, 0, 0, 60, 0, UInt8(bytes.count)] + bytes
    }
    return out
}

private func answers(_ ips: [String], tc: Bool = false) -> (([UInt8], Bool) -> FakeDNS.Reply) {
    { q, _ in FakeDNS.Reply(bytes: canned(q, ips, tc: tc)) }
}

private func udpExchange(port: UInt16, _ query: [UInt8], timeout: TimeInterval = 3) -> [UInt8]? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(fd) }
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    sin.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &sin) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, query, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = recv(fd, &buf, buf.count, 0)
    return n > 0 ? Array(buf[0..<n]) : nil
}

private func tcpConnect(port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    sin.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &sin) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    return fd
}

private func tcpQuery(_ fd: Int32, _ query: [UInt8], timeout: TimeInterval = 3) -> [UInt8]? {
    guard sendAll(fd, [UInt8(query.count >> 8), UInt8(query.count & 0xFF)] + query),
          let head = recvExactly(fd, 2, timeout: timeout) else { return nil }
    return recvExactly(fd, Int(head[0]) << 8 | Int(head[1]), timeout: timeout)
}

private func q(_ name: String, _ type: UInt16 = 1) -> [UInt8] { DNSMessage.query(id: .random(in: 1...60000), name: name, type: type) }
private func rcode(_ r: [UInt8]) -> UInt8 { r[3] & 0x0F }
private func ancount(_ r: [UInt8]) -> Int { Int(r[6]) << 8 | Int(r[7]) }

private final class Learned {
    private let lock = NSLock()
    private var events: [(SplitRule, [IPAddress])] = []
    var delay: TimeInterval = 0
    var done = false
    var all: [(SplitRule, [IPAddress])] { lock.lock(); defer { lock.unlock() }; return events }
    func record(_ r: SplitRule, _ a: [IPAddress]) {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock(); events.append((r, a)); done = true; lock.unlock()
    }
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
}

private let example = SplitRule.domain("example.com")

private func config(rules: [SplitRule] = [example], listed: [FakeDNS] = [], normal: [FakeDNS] = [],
                    ipv6: Bool = false, fallback: Bool = false) -> SplitDNSConfig {
    SplitDNSConfig(rules: rules, listed: listed.map(\.upstream), normal: normal.map(\.upstream),
                   tunnelIPv6: ipv6, listedFallsBackToNormal: fallback, allowLoopbackUpstreams: true)
}

private func makeProxy(_ cfg: SplitDNSConfig, learned: Learned = Learned(), timeout: TimeInterval = 0.2,
                       idle: TimeInterval = 0.5) throws -> SplitDNSProxy {
    let p = SplitDNSProxy(listen: IPAddress("127.0.0.1")!, port: 0, config: cfg, timeout: timeout, idleTimeout: idle) {
        learned.record($0, $1)
    }
    try p.start()
    return p
}

// MARK: tests

/// Serialized: they all open sockets and threads, and the rest of the suite has timing-sensitive tests.
@Suite(.serialized) struct SplitDNSProxyTests {

    @Test func configDropsLoopbackUpstreams() {
        let cfg = SplitDNSConfig(rules: [], listed: [DNSUpstream(address: IPAddress("127.0.0.1")!),
                                                     DNSUpstream(address: IPAddress("::1")!),
                                                     DNSUpstream(address: IPAddress("198.51.100.1")!)],
                                 normal: [DNSUpstream(address: IPAddress("127.5.5.5")!), DNSUpstream(address: IPAddress("0.0.0.0")!),
                                          DNSUpstream(address: IPAddress("2001:db8::1")!, port: 5353)],
                                 tunnelIPv6: false)
        #expect(cfg.listed == [DNSUpstream(address: IPAddress("198.51.100.1")!)])
        #expect(cfg.normal == [DNSUpstream(address: IPAddress("2001:db8::1")!, port: 5353)])
    }

    @Test func forwardsNonMatchingNamesToNormalUpstream() throws {
        let normal = try FakeDNS(handler: answers(["203.0.113.7"]))
        let listed = try FakeDNS(handler: answers(["198.51.100.9"]))
        defer { normal.stop(); listed.stop() }
        let learned = Learned()
        let proxy = try makeProxy(config(listed: [listed], normal: [normal]), learned: learned)
        defer { proxy.stop() }
        #expect(proxy.boundPort != 0)

        let query = q("www.example.net")
        let reply = try #require(udpExchange(port: proxy.boundPort, query))
        #expect(reply == canned(query, ["203.0.113.7"]))
        #expect(normal.hits.count == 1 && listed.hits.isEmpty)
        #expect(learned.all.isEmpty)
    }

    @Test func matchingNamesUseListedUpstreamAndLearnBeforeReply() throws {
        let normal = try FakeDNS(handler: answers(["203.0.113.7"]))
        let listed = try FakeDNS(handler: answers(["198.51.100.9", "198.51.100.10"]))
        defer { normal.stop(); listed.stop() }
        let learned = Learned()
        learned.delay = 0.15      // the hook is slow: the reply must still wait for it
        let proxy = try makeProxy(config(listed: [listed], normal: [normal]), learned: learned)
        defer { proxy.stop() }

        let reply = try #require(udpExchange(port: proxy.boundPort, q("App.Example.com")))
        #expect(learned.isDone)
        #expect(ancount(reply) == 2)
        #expect(learned.all.count == 1)
        #expect(learned.all[0].0 == example)
        #expect(learned.all[0].1 == [IPAddress("198.51.100.9")!, IPAddress("198.51.100.10")!])
        #expect(listed.hits.count == 1 && normal.hits.isEmpty)
    }

    @Test func failedListedFallsBackToNormalAndStillLearns() throws {
        let dead = try FakeDNS { _, _ in FakeDNS.Reply(bytes: nil) }
        let normal = try FakeDNS(handler: answers(["203.0.113.7"]))
        defer { dead.stop(); normal.stop() }
        let learned = Learned()
        let proxy = try makeProxy(config(listed: [dead], normal: [normal], fallback: true), learned: learned)
        defer { proxy.stop() }

        let query = q("app.example.com")
        #expect(udpExchange(port: proxy.boundPort, query) == canned(query, ["203.0.113.7"]))
        #expect(dead.hits.count == 1 && normal.hits.count == 1)
        #expect(learned.all.count == 1)
        #expect(learned.all[0].0 == example)
        #expect(learned.all[0].1 == [IPAddress("203.0.113.7")!])
    }

    @Test func failedListedWithoutFallbackIsServfailAndLearnsNothing() throws {
        let dead = try FakeDNS { _, _ in FakeDNS.Reply(bytes: nil) }
        let normal = try FakeDNS(handler: answers(["203.0.113.7"]))
        defer { dead.stop(); normal.stop() }
        let learned = Learned()
        let proxy = try makeProxy(config(listed: [dead], normal: [normal], fallback: false), learned: learned)
        defer { proxy.stop() }

        let r = try #require(udpExchange(port: proxy.boundPort, q("app.example.com")))
        #expect(rcode(r) == 2)
        #expect(normal.hits.isEmpty)
        #expect(learned.all.isEmpty)
    }

    @Test func emptyListedFallsBackToNormal() throws {
        let normal = try FakeDNS(handler: answers(["198.51.100.9"]))
        defer { normal.stop() }
        let learned = Learned()
        let proxy = try makeProxy(config(listed: [], normal: [normal]), learned: learned)
        defer { proxy.stop() }
        _ = try #require(udpExchange(port: proxy.boundPort, q("example.com")))
        #expect(normal.hits.count == 1)
        #expect(learned.all.count == 1)
    }

    @Test func suppressedTypesGetEmptyAnswerWithoutUpstream() throws {
        let up = try FakeDNS(handler: answers(["198.51.100.9"]))
        defer { up.stop() }
        let proxy = try makeProxy(config(listed: [up], normal: [up], ipv6: false))
        defer { proxy.stop() }

        // AAAA for a matching name without tunnel IPv6, and HTTPS (65) always.
        for type: UInt16 in [28, 65] {
            let query = q("www.example.com", type)
            let r = try #require(udpExchange(port: proxy.boundPort, query))
            #expect(Array(r[0..<2]) == Array(query[0..<2]))
            #expect(rcode(r) == 0 && ancount(r) == 0)
        }
        #expect(up.hits.isEmpty)

        // Non-matching names are forwarded as usual, whatever the type.
        _ = try #require(udpExchange(port: proxy.boundPort, q("www.example.net", 28)))
        #expect(up.hits.count == 1)

        // With tunnel IPv6 the AAAA goes through, HTTPS is still answered locally.
        proxy.update(config(listed: [up], normal: [up], ipv6: true))
        _ = try #require(udpExchange(port: proxy.boundPort, q("www.example.com", 28)))
        let https = try #require(udpExchange(port: proxy.boundPort, q("www.example.com", 65)))
        #expect(ancount(https) == 0)
        #expect(up.hits.count == 2)
    }

    @Test func truncatedUDPReplyPassesThroughAndTCPRetryWorks() throws {
        let up = try FakeDNS { query, tcp in
            tcp ? FakeDNS.Reply(bytes: canned(query, ["198.51.100.9", "198.51.100.10", "198.51.100.11"]))
                : FakeDNS.Reply(bytes: canned(query, tc: true))
        }
        defer { up.stop() }
        let learned = Learned()
        let proxy = try makeProxy(config(listed: [up], normal: [up]), learned: learned)
        defer { proxy.stop() }

        let query = q("big.example.com")
        let udp = try #require(udpExchange(port: proxy.boundPort, query))
        #expect(udp[2] & 0x02 != 0)               // TC survived
        #expect(ancount(udp) == 0)
        #expect(learned.all.isEmpty)

        let fd = tcpConnect(port: proxy.boundPort)
        defer { close(fd) }
        let tcp = try #require(tcpQuery(fd, query))
        #expect(ancount(tcp) == 3)
        #expect(learned.all.count == 1 && learned.all[0].1.count == 3)
        #expect(up.hits.map(\.tcp) == [false, true])
    }

    @Test func oneTCPConnectionCarriesSeveralQueriesThenIdlesOut() throws {
        let up = try FakeDNS(handler: answers(["203.0.113.7"]))
        defer { up.stop() }
        let proxy = try makeProxy(config(listed: [up], normal: [up]), idle: 0.4)
        defer { proxy.stop() }
        let fd = tcpConnect(port: proxy.boundPort)
        defer { close(fd) }
        for name in ["a.example.net", "b.example.net", "c.example.com"] {
            let query = q(name)
            #expect(tcpQuery(fd, query) == canned(query, ["203.0.113.7"]))
        }
        // After the idle timeout the proxy closes: read sees EOF.
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        #expect(poll(&pfd, 1, 3000) > 0)
        var byte: UInt8 = 0
        #expect(read(fd, &byte, 1) == 0)
    }

    @Test func timeoutMovesToNextServerThenServfail() throws {
        let dead = try FakeDNS { _, _ in FakeDNS.Reply(bytes: nil) }
        let alsoDead = try FakeDNS { _, _ in FakeDNS.Reply(bytes: nil) }
        let alive = try FakeDNS(handler: answers(["203.0.113.7"]))
        defer { dead.stop(); alsoDead.stop(); alive.stop() }

        let proxy = try makeProxy(config(listed: [], normal: [dead, alive]), timeout: 0.2)
        let query = q("www.example.net")
        let start = Date()
        #expect(udpExchange(port: proxy.boundPort, query) == canned(query, ["203.0.113.7"]))
        #expect(Date().timeIntervalSince(start) >= 0.2)
        #expect(dead.hits.count == 1 && alive.hits.count == 1)
        proxy.stop()

        let failing = try makeProxy(config(listed: [], normal: [dead, alsoDead]), timeout: 0.2)
        defer { failing.stop() }
        let r = try #require(udpExchange(port: failing.boundPort, query))
        #expect(rcode(r) == 2)
        #expect(Array(r[0..<2]) == Array(query[0..<2]))

        // Same over TCP.
        let fd = tcpConnect(port: failing.boundPort)
        defer { close(fd) }
        #expect(rcode(try #require(tcpQuery(fd, query))) == 2)
    }

    @Test func ignoresRepliesWithTheWrongID() throws {
        let up = try FakeDNS { query, _ in
            var wrong = canned(query, ["203.0.113.7"])
            wrong[0] ^= 0xFF
            return FakeDNS.Reply(bytes: wrong)
        }
        defer { up.stop() }
        let proxy = try makeProxy(config(listed: [], normal: [up]))
        defer { proxy.stop() }
        #expect(rcode(try #require(udpExchange(port: proxy.boundPort, q("www.example.net")))) == 2)
    }

    @Test func portInUseThrows() throws {
        let first = try makeProxy(config())
        defer { first.stop() }
        let second = SplitDNSProxy(listen: IPAddress("127.0.0.1")!, port: first.boundPort, config: config()) { _, _ in }
        #expect(throws: SplitDNSError.portInUse) { try second.start() }
        second.stop()    // harmless after a failed start
    }

    @Test func rulesAndUpstreamsSwapAtRuntime() throws {
        let a = try FakeDNS(handler: answers(["203.0.113.7"]))
        let b = try FakeDNS(handler: answers(["198.51.100.9"]))
        defer { a.stop(); b.stop() }
        let learned = Learned()
        let proxy = try makeProxy(config(rules: [], listed: [b], normal: [a]), learned: learned)
        defer { proxy.stop() }

        _ = try #require(udpExchange(port: proxy.boundPort, q("www.example.com")))
        #expect(a.hits.count == 1 && b.hits.isEmpty && learned.all.isEmpty)

        proxy.update(config(rules: [example], listed: [b], normal: [a]))
        _ = try #require(udpExchange(port: proxy.boundPort, q("www.example.com")))
        #expect(b.hits.count == 1 && learned.all.count == 1)

        proxy.update(config(rules: [example], listed: [a], normal: [b]))
        _ = try #require(udpExchange(port: proxy.boundPort, q("www.example.com")))
        #expect(a.hits.count == 2)
    }

    @Test func inFlightQueryKeepsItsConfigWhileUpdateSwaps() throws {
        let slow = try FakeDNS { query, _ in FakeDNS.Reply(bytes: canned(query, ["203.0.113.7"]), delay: 0.3) }
        let other = try FakeDNS(handler: answers(["198.51.100.9"]))
        defer { slow.stop(); other.stop() }
        let proxy = try makeProxy(config(rules: [], normal: [slow]), timeout: 2)
        defer { proxy.stop() }
        let query = q("www.example.net")
        var result: [UInt8]?
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { result = udpExchange(port: proxy.boundPort, query); done.signal() }
        Thread.sleep(forTimeInterval: 0.1)
        proxy.update(config(rules: [], normal: [other]))
        done.wait()
        #expect(result == canned(query, ["203.0.113.7"]))
        #expect(other.hits.isEmpty)
    }

    @Test func stopWhileQueryInFlightIsPromptAndSilencesLearn() throws {
        let slow = try FakeDNS { query, _ in FakeDNS.Reply(bytes: canned(query, ["198.51.100.9"]), delay: 1.5) }
        defer { slow.stop() }
        let learned = Learned()
        let proxy = try makeProxy(config(listed: [slow], normal: [slow]), learned: learned, timeout: 5)
        Thread.detachNewThread { _ = udpExchange(port: proxy.boundPort, q("www.example.com"), timeout: 3) }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(slow.hits.count == 1)
        let start = Date()
        proxy.stop()
        #expect(Date().timeIntervalSince(start) < 1.0)
        Thread.sleep(forTimeInterval: 1.6)
        #expect(learned.all.isEmpty)
        proxy.stop()      // twice is fine
        // The port is free again.
        let again = SplitDNSProxy(listen: IPAddress("127.0.0.1")!, port: 0, config: config()) { _, _ in }
        try again.start()
        again.stop()
    }

    @Test func resolveNowLearnsAAndAAAA() throws {
        let up = try FakeDNS { query, _ in
            let type = DNSMessage.parseQuery(query)!.type
            return FakeDNS.Reply(bytes: canned(query, type == 28 ? ["2001:db8::9"] : ["198.51.100.9"]))
        }
        defer { up.stop() }
        let learned = Learned()
        let proxy = try makeProxy(config(listed: [up], normal: [], ipv6: true), learned: learned)
        defer { proxy.stop() }

        #expect(proxy.resolveNow(name: "www.example.com") == [IPAddress("198.51.100.9")!, IPAddress("2001:db8::9")!])
        #expect(learned.all.count == 2)
        #expect(learned.all.allSatisfy { $0.0 == example })
        #expect(proxy.resolveNow(name: "www.example.net").isEmpty)

        proxy.update(config(listed: [up], normal: [], ipv6: false))
        #expect(proxy.resolveNow(name: "example.com") == [IPAddress("198.51.100.9")!])
        #expect(up.hits.filter { $0.type == 28 }.count == 1)
    }
}

// MARK: bound upstreams

extension SplitDNSProxyTests {
    private func tcpOnce(_ port: UInt16, _ query: [UInt8]) -> [UInt8]? {
        let fd = tcpConnect(port: port)
        defer { close(fd) }
        return tcpQuery(fd, query)
    }

    private func boundConfig(_ fake: FakeDNS, interface: String?) -> SplitDNSConfig {
        var up = fake.upstream
        up.interface = interface
        return SplitDNSConfig(rules: [example], listed: [up], normal: [up], tunnelIPv6: false, allowLoopbackUpstreams: true)
    }

    @Test func upstreamBoundToLoopbackInterfaceStillAnswers() throws {
        let fake = try FakeDNS(handler: answers(["198.51.100.9"]))
        defer { fake.stop() }
        let proxy = try makeProxy(boundConfig(fake, interface: "lo0"))
        defer { proxy.stop() }
        let query = q("example.com")
        let udp = try #require(udpExchange(port: proxy.boundPort, query))
        #expect(udp == canned(query, ["198.51.100.9"]))
        let tq = q("example.com")
        #expect(tcpOnce(proxy.boundPort, tq) == canned(tq, ["198.51.100.9"]))
        #expect(fake.hits.contains { !$0.tcp } && fake.hits.contains { $0.tcp })
    }

    @Test func unknownInterfaceNameFallsBackToUnbound() throws {
        let fake = try FakeDNS(handler: answers(["198.51.100.9"]))
        defer { fake.stop() }
        let proxy = try makeProxy(boundConfig(fake, interface: "nonexistent99"))
        defer { proxy.stop() }
        let query = q("example.com")
        #expect(try #require(udpExchange(port: proxy.boundPort, query)) == canned(query, ["198.51.100.9"]))
        let tq = q("example.com")
        #expect(tcpOnce(proxy.boundPort, tq) == canned(tq, ["198.51.100.9"]))
    }

    @Test func upstreamInterfaceDefaultsToNil() {
        #expect(DNSUpstream(address: IPAddress("198.51.100.1")!).interface == nil)
        #expect(DNSUpstream(address: IPAddress("198.51.100.1")!, port: 53, interface: "en0").interface == "en0")
    }
}
