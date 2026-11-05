import Foundation
import Darwin
import WirelyCore

public struct DNSUpstream: Equatable {
    public var address: IPAddress
    public var port: UInt16
    /// Bind this upstream's sockets to the named interface (`IP_BOUND_IF`), so queries leave through it
    /// even when the routing table says otherwise. nil, or a name the system doesn't know = unbound.
    public var interface: String?
    public init(address: IPAddress, port: UInt16 = 53, interface: String? = nil) {
        self.address = address
        self.port = port
        self.interface = interface
    }
}

extension IPAddress {
    var isLoopbackOrUnspecified: Bool {
        if bytes.count == 4 { return bytes[0] == 127 || bytes.allSatisfy { $0 == 0 } }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 0 || bytes.last == 1 { return true }
        // ::ffff:127.x.x.x
        return bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF && bytes[12] == 127
    }
}

/// What the proxy decides with; swapped atomically by `SplitDNSProxy.update(_:)`.
public struct SplitDNSConfig {
    public private(set) var rules: [SplitRule]
    /// Upstreams for names that match a rule (the profile's DNS servers, through the tunnel).
    public private(set) var listed: [DNSUpstream]
    /// Upstreams for everything else.
    public private(set) var normal: [DNSUpstream]
    /// The tunnel has an IPv6 address: AAAA answers are learned instead of suppressed.
    public var tunnelIPv6: Bool
    /// When every listed upstream fails, a matching name is tried on the normal upstreams before SERVFAIL.
    /// Exclude mode only: in include mode listed names must never go to the network's DNS.
    public var listedFallsBackToNormal: Bool

    /// Loopback and unspecified upstreams are dropped (the proxy would query itself), unless
    /// `allowLoopbackUpstreams` is set; only tests need that, to reach a fake server on 127.0.0.1.
    public init(rules: [SplitRule], listed: [DNSUpstream], normal: [DNSUpstream], tunnelIPv6: Bool,
                listedFallsBackToNormal: Bool = false, allowLoopbackUpstreams: Bool = false) {
        func keep(_ list: [DNSUpstream]) -> [DNSUpstream] {
            allowLoopbackUpstreams ? list : list.filter { !$0.address.isLoopbackOrUnspecified }
        }
        self.rules = rules
        self.listed = keep(listed)
        self.normal = keep(normal)
        self.tunnelIPv6 = tunnelIPv6
        self.listedFallsBackToNormal = listedFallsBackToNormal
    }
}

public enum SplitDNSError: Error, Equatable {
    /// Another process already owns the UDP or TCP port.
    case portInUse
    case socket(Int32)
}

/// Local DNS forwarder (UDP + TCP). Names that match a rule go to the listed upstreams and their answers are
/// reported to `onLearn` BEFORE the reply reaches the client; everything else goes to the normal upstreams.
public final class SplitDNSProxy {
    private let listenAddress: IPAddress
    private let requestedPort: UInt16
    private let timeout: TimeInterval
    private let idleTimeout: TimeInterval
    private let onLearn: (SplitRule, [IPAddress]) -> Void

    private let lock = NSLock()
    private var config: SplitDNSConfig
    private var stopped = false
    private var started = false
    private var fds: [Int32] = []
    private var port: UInt16 = 0
    /// Serialises the learn hook against `stop()`: after stop() returns it never runs again.
    private let learnLock = NSLock()
    /// Own threads (not GCD): a blocked pool must never starve queries or `stop()`.
    private let group = DispatchGroup()

    public init(listen: IPAddress, port: UInt16, config: SplitDNSConfig, timeout: TimeInterval = 2,
                idleTimeout: TimeInterval = 5, onLearn: @escaping (SplitRule, [IPAddress]) -> Void) {
        self.listenAddress = listen
        self.requestedPort = port
        self.config = config
        self.timeout = timeout
        self.idleTimeout = idleTimeout
        self.onLearn = onLearn
    }

    /// The port actually bound (differs from the requested one when that was 0).
    public var boundPort: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return port
    }

    public func update(_ new: SplitDNSConfig) {
        lock.lock(); defer { lock.unlock() }
        config = new
    }

    private var currentConfig: SplitDNSConfig {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    // MARK: lifecycle

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started, !stopped else { return }
        var attempt = 0
        var udp: Int32 = -1
        var tcp: Int32 = -1
        while true {
            udp = try bind(type: SOCK_DGRAM, port: requestedPort)
            let chosen = Self.localPort(udp)
            do {
                tcp = try bind(type: SOCK_STREAM, port: chosen)
                if Darwin.listen(tcp, 64) != 0 { throw SplitDNSError.socket(errno) }
                port = chosen
                break
            } catch {
                close(udp)
                if tcp >= 0 { close(tcp); tcp = -1 }
                // Port 0 picked a UDP port whose TCP twin is taken: try another.
                if requestedPort == 0, error as? SplitDNSError == .portInUse, attempt < 10 {
                    attempt += 1
                    continue
                }
                throw error
            }
        }
        fds = [udp, tcp]
        started = true
        let (u, t) = (udp, tcp)
        group.enter()
        Thread.detachNewThread { [self] in defer { group.leave() }; udpLoop(u) }
        group.enter()
        Thread.detachNewThread { [self] in defer { group.leave() }; tcpLoop(t) }
    }

    /// Closes the sockets and waits for in-flight queries and hooks. Safe to call twice.
    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        learnLock.lock()
        learnLock.unlock()
        group.wait()
        lock.lock()
        let toClose = fds
        fds = []
        lock.unlock()
        for fd in toClose { close(fd) }
    }

    private func bind(type: Int32, port: UInt16) throws -> Int32 {
        let family = listenAddress.family == .v4 ? AF_INET : AF_INET6
        let fd = socket(family, type, 0)
        guard fd >= 0 else { throw SplitDNSError.socket(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if type == SOCK_STREAM { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var (ss, len) = Self.makeSockAddr(listenAddress, port: port)
        let rc = withUnsafePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw e == EADDRINUSE ? SplitDNSError.portInUse : SplitDNSError.socket(e)
        }
        return fd
    }

    // MARK: listeners

    private func udpLoop(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65535)
        while !isStopped {
            guard Self.waitFor(fd, events: Int16(POLLIN), deadline: nil, stop: { isStopped }) else { continue }
            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            guard n > 0 else { continue }
            let packet = Array(buf[0..<n])
            let (client, clientLen) = (from, fromLen)
            group.enter()
            Thread.detachNewThread { [self] in
                defer { group.leave() }
                guard let reply = respond(to: packet, tcp: false), !isStopped else { return }
                var dest = client
                _ = withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, clientLen) }
                }
            }
        }
    }

    private func tcpLoop(_ fd: Int32) {
        while !isStopped {
            guard Self.waitFor(fd, events: Int16(POLLIN), deadline: nil, stop: { isStopped }) else { continue }
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL) | O_NONBLOCK)
            group.enter()
            Thread.detachNewThread { [self] in
                defer { group.leave(); close(conn) }
                serve(connection: conn)
            }
        }
    }

    /// Several length-prefixed queries in sequence; closes after `idleTimeout` without one.
    private func serve(connection fd: Int32) {
        while !isStopped {
            guard let head = readExactly(fd, 2, deadline: Date().addingTimeInterval(idleTimeout)) else { return }
            let length = Int(head[0]) << 8 | Int(head[1])
            guard length > 0, let query = readExactly(fd, length, deadline: Date().addingTimeInterval(idleTimeout)),
                  let reply = respond(to: query, tcp: true), !isStopped, reply.count <= 0xFFFF else { return }
            let framed = [UInt8(reply.count >> 8), UInt8(reply.count & 0xFF)] + reply
            guard writeAll(fd, framed, deadline: Date().addingTimeInterval(idleTimeout)) else { return }
        }
    }

    // MARK: query handling

    /// The reply for one query, or nil when it should be dropped (unparseable, or the proxy is stopping).
    private func respond(to query: [UInt8], tcp: Bool) -> [UInt8]? {
        guard let q = DNSMessage.parseQuery(query) else { return nil }
        let cfg = currentConfig
        let rule = SplitRule.matchingRule(for: q.name, in: cfg.rules)
        if rule != nil, q.type == DNSMessage.typeHTTPS || (q.type == DNSMessage.typeAAAA && !cfg.tunnelIPv6) {
            return DNSMessage.emptyResponse(to: query) ?? DNSMessage.servfail(to: query)
        }
        let useListed = rule != nil && !cfg.listed.isEmpty
        var attempts = [useListed ? cfg.listed : cfg.normal]
        if useListed, cfg.listedFallsBackToNormal { attempts.append(cfg.normal) }
        for servers in attempts {
            for server in servers {
                guard !isStopped else { return nil }
                let reply = tcp ? forwardTCP(query, to: server, id: q.id) : forwardUDP(query, to: server, id: q.id)
                if let reply {
                    if let rule { learn(rule, DNSMessage.answerAddresses(reply)) }
                    return reply
                }
            }
        }
        return DNSMessage.servfail(to: query)
    }

    private func learn(_ rule: SplitRule, _ addresses: [IPAddress]) {
        guard !addresses.isEmpty else { return }
        learnLock.lock(); defer { learnLock.unlock() }
        if isStopped { return }
        onLearn(rule, addresses)
    }

    /// Resolves a rule's name (A, plus AAAA with tunnel IPv6) through its upstreams, reports the answers to
    /// `onLearn` and returns them. Empty if no rule matches `name`.
    public func resolveNow(name: String) -> [IPAddress] {
        let cfg = currentConfig
        guard SplitRule.matchingRule(for: name, in: cfg.rules) != nil else { return [] }
        var out: [IPAddress] = []
        for type in [DNSMessage.typeA] + (cfg.tunnelIPv6 ? [DNSMessage.typeAAAA] : []) {
            let query = DNSMessage.query(id: UInt16.random(in: 0...UInt16.max), name: name, type: type)
            guard !query.isEmpty, let reply = respond(to: query, tcp: false) else { continue }
            for a in DNSMessage.answerAddresses(reply) where !out.contains(a) { out.append(a) }
        }
        return out
    }

    // MARK: upstream I/O

    private func forwardUDP(_ query: [UInt8], to server: DNSUpstream, id: UInt16) -> [UInt8]? {
        let fd = socket(server.address.family == .v4 ? AF_INET : AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        Self.bindToInterface(fd, server)
        var (ss, len) = Self.makeSockAddr(server.address, port: server.port)
        let rc = withUnsafePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard rc == 0, send(fd, query, query.count, 0) == query.count else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 65535)
        while Self.waitFor(fd, events: Int16(POLLIN), deadline: deadline, stop: { isStopped }) {
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0 { return nil }   // e.g. ECONNREFUSED from an ICMP error
            if n >= 12, UInt16(buf[0]) << 8 | UInt16(buf[1]) == id, buf[2] & 0x80 != 0 { return Array(buf[0..<n]) }
        }
        return nil
    }

    private func forwardTCP(_ query: [UInt8], to server: DNSUpstream, id: UInt16) -> [UInt8]? {
        let fd = socket(server.address.family == .v4 ? AF_INET : AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        Self.bindToInterface(fd, server)
        let deadline = Date().addingTimeInterval(timeout)
        var (ss, len) = Self.makeSockAddr(server.address, port: server.port)
        let rc = withUnsafePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS,
                  Self.waitFor(fd, events: Int16(POLLOUT), deadline: deadline, stop: { isStopped }) else { return nil }
            var err: Int32 = 0
            var errLen = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen) == 0, err == 0 else { return nil }
        }
        guard writeAll(fd, [UInt8(query.count >> 8), UInt8(query.count & 0xFF)] + query, deadline: deadline),
              let head = readExactly(fd, 2, deadline: deadline) else { return nil }
        let length = Int(head[0]) << 8 | Int(head[1])
        guard length >= 12, let reply = readExactly(fd, length, deadline: deadline),
              UInt16(reply[0]) << 8 | UInt16(reply[1]) == id else { return nil }
        return reply
    }

    private func readExactly(_ fd: Int32, _ count: Int, deadline: Date) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            guard Self.waitFor(fd, events: Int16(POLLIN), deadline: deadline, stop: { isStopped }) else { return nil }
            let n = out.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
            if n > 0 { got += n } else if n == 0 || (errno != EAGAIN && errno != EINTR) { return nil }
        }
        return out
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8], deadline: Date) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n > 0 {
                sent += n
            } else if n < 0, errno == EAGAIN || errno == EINTR {
                guard Self.waitFor(fd, events: Int16(POLLOUT), deadline: deadline, stop: { isStopped }) else { return false }
            } else {
                return false
            }
        }
        return true
    }

    // MARK: helpers

    /// Polls in short slices so a stopping proxy never waits out a full timeout. True = ready.
    private static func waitFor(_ fd: Int32, events: Int16, deadline: Date?, stop: () -> Bool) -> Bool {
        while true {
            if stop() { return false }
            var slice: Int32 = 100
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return false }
                slice = Int32(max(1, min(100, remaining * 1000)))
            }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let r = poll(&pfd, 1, slice)
            if r > 0 { return true }
            if r < 0 && errno != EINTR { return false }
            if deadline == nil { return false }   // listeners re-check their stop flag
        }
    }

    /// Pins an upstream socket to its interface. Index 0 (unknown name) or a failing setsockopt leaves it unbound.
    private static func bindToInterface(_ fd: Int32, _ server: DNSUpstream) {
        guard let name = server.interface else { return }
        var index = if_nametoindex(name)
        guard index != 0 else { return }
        if server.address.family == .v4 {
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        } else {
            setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
    }

    private static func makeSockAddr(_ ip: IPAddress, port: UInt16) -> (sockaddr_storage, socklen_t) {
        var ss = sockaddr_storage()
        if ip.family == .v4 {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &sin.sin_addr) { $0.copyBytes(from: ip.bytes) }
            withUnsafeBytes(of: &sin) { src in withUnsafeMutableBytes(of: &ss) { $0.copyMemory(from: src) } }
            return (ss, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        var sin6 = sockaddr_in6()
        sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sin6.sin6_family = sa_family_t(AF_INET6)
        sin6.sin6_port = port.bigEndian
        withUnsafeMutableBytes(of: &sin6.sin6_addr) { $0.copyBytes(from: ip.bytes) }
        withUnsafeBytes(of: &sin6) { src in withUnsafeMutableBytes(of: &ss) { $0.copyMemory(from: src) } }
        return (ss, socklen_t(MemoryLayout<sockaddr_in6>.size))
    }

    private static func localPort(_ fd: Int32) -> UInt16 {
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return withUnsafeBytes(of: &ss) { raw in
            // sin_port / sin6_port sit at the same offset (2).
            UInt16(raw[2]) << 8 | UInt16(raw[3])
        }
    }
}
