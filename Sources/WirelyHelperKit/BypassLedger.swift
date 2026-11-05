import Foundation
import Darwin
import WirelyCore

/// Every exclude-mode bypass route (static and learned) that is currently installed. Bypass routes go
/// through the physical gateway, so they do NOT vanish with the utun: a leftover one would leak in the
/// next full-tunnel session. The ledger is a JSON array of network strings, rewritten atomically on every
/// change, so teardown and `cleanupStale` (after a crash) can delete exactly what was added.
/// Thread-safe: the manager queue and the DNS learn hook both write to it.
public final class BypassLedger {
    private let path: String
    private let lock = NSLock()
    private var entries: [IPNetwork] = []

    /// Loads whatever a previous run left behind.
    public init(path: String = HelperConstants.bypassPath) {
        self.path = path
        if let data = FileManager.default.contents(atPath: path),
           let texts = try? JSONDecoder().decode([String].self, from: data) {
            for n in texts.compactMap({ IPNetwork($0) }) where !entries.contains(n) { entries.append(n) }
        }
    }

    public var all: [IPNetwork] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// Records `nets` durably BEFORE the routes exist. On a write error nothing is recorded and it throws.
    public func add(_ nets: [IPNetwork]) throws {
        lock.lock(); defer { lock.unlock() }
        var next = entries
        for n in nets where !next.contains(n) { next.append(n) }
        guard next != entries else { return }
        try write(next)
        entries = next
    }

    /// Forgets `nets` (best effort: a failed write only leaves a stale entry whose delete is harmless).
    public func remove(_ nets: [IPNetwork]) {
        lock.lock(); defer { lock.unlock() }
        let next = entries.filter { !nets.contains($0) }
        guard next != entries else { return }
        entries = next
        try? write(next)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        guard !entries.isEmpty else { return }
        entries = []
        unlink(path)
    }

    private func write(_ list: [IPNetwork]) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(list.map(\.description))
        let tmp = dir + "/.bypass-\(UUID().uuidString).tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = true
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    ok = false
                    return
                }
                off += n
            }
        }
        let writeErr = errno
        if ok { fsync(fd) }
        close(fd)
        guard ok else {
            unlink(tmp)
            throw POSIXError(POSIXErrorCode(rawValue: writeErr) ?? .EIO)
        }
        if rename(tmp, path) != 0 {
            let e = errno
            unlink(tmp)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
    }
}

/// Which addresses are never bypass-routed in exclude mode.
struct BypassFilter {
    /// Resolved tunnel endpoints (they already have their own route).
    var endpoints: [IPAddress] = []
    /// The profile's own non-default AllowedIPs networks (routed into the tunnel on purpose).
    var profileNets: [IPNetwork] = []
    /// Directly connected IPv4 subnets of the primary interface: already outside the tunnel, and a
    /// gateway route would send them via the router instead.
    var connected: [IPNetwork] = []

    private static let loopback = IPNetwork("127.0.0.0/8")!
    private static let linkLocal = IPNetwork("169.254.0.0/16")!

    private static func inside(_ net: IPNetwork, _ region: IPNetwork) -> Bool {
        region.prefixLength <= net.prefixLength && region.contains(net.address)
    }

    /// nil = route it via the gateway; otherwise a short Turkish reason for the log.
    func skipReason(_ net: IPNetwork) -> String? {
        if net.prefixLength == 0 { return "varsayılan rota" }
        if net.prefixLength == 32, endpoints.contains(net.address) { return "tünel uç noktası" }
        if BypassFilter.inside(net, BypassFilter.loopback) || BypassFilter.inside(net, BypassFilter.linkLocal) {
            return "loopback/link-local"
        }
        if profileNets.contains(where: { BypassFilter.inside(net, $0) }) { return "profilin kendi ağı" }
        if connected.contains(where: { BypassFilter.inside(net, $0) }) { return "doğrudan bağlı alt ağ" }
        return nil
    }
}
