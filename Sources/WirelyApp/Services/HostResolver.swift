import Foundation
import WirelyCore

enum HostResolver {
    /// Literal IPs return themselves; otherwise getaddrinfo (off the caller's thread), preferring IPv4.
    static func resolve(_ host: String) async -> String? {
        if IPAddress(host) != nil { return host }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: lookup(host))
            }
        }
    }

    private static func lookup(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let head = res else { return nil }
        defer { freeaddrinfo(res) }

        var v6: String?
        var p: UnsafeMutablePointer<addrinfo>? = head
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let sa = ai.pointee.ai_addr,
               getnameinfo(sa, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: buf)
                if ai.pointee.ai_family == AF_INET { return s }
                if v6 == nil, ai.pointee.ai_family == AF_INET6 { v6 = s }
            }
            p = ai.pointee.ai_next
        }
        return v6
    }
}
