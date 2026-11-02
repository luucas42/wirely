import Foundation
import Darwin

/// Host names from reverse DNS (mDNS answers `.local` names on most home networks).
enum ReverseDNS {
    private static let suffixes = [".home.arpa", ".localdomain", ".local", ".lan", ".home"]

    /// Drops a trailing dot and the local suffixes; nil when nothing is left or the name is just the address.
    static func clean(_ name: String, ip: String) -> String? {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.hasSuffix(".") { n.removeLast() }
        for s in suffixes where n.lowercased().hasSuffix(s) {
            n = String(n.dropLast(s.count))
            break
        }
        return n.isEmpty || n == ip ? nil : n
    }

    /// Names for `ips`, whatever finished within `budget` seconds (stragglers are not waited for).
    static func names(for ips: [String], budget: Double = 1.0) async -> [String: String] {
        guard !ips.isEmpty else { return [:] }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let box = Box()
                let group = DispatchGroup()
                for ip in ips {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        if let n = lookup(ip).flatMap({ clean($0, ip: ip) }) { box.set(ip, n) }
                        group.leave()
                    }
                }
                _ = group.wait(timeout: .now() + budget)
                cont.resume(returning: box.snapshot())
            }
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func set(_ k: String, _ v: String) { lock.withLock { values[k] = v } }
        func snapshot() -> [String: String] { lock.withLock { values } }
    }

    private static func lookup(_ ip: String) -> String? {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &sa.sin_addr) == 1 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        return rc == 0 ? String(cString: host) : nil
    }
}
