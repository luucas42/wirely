import Foundation
import Darwin
import WirelyCore

public struct SystemResolver: EndpointResolver {
    public init() {}

    public func resolve(_ endpoint: Endpoint) throws -> IPAddress {
        if let literal = IPAddress(endpoint.host) { return literal }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(endpoint.host, nil, &hints, &res) == 0, let head = res else {
            throw TunnelError.resolve(endpoint.host)
        }
        defer { freeaddrinfo(head) }

        var firstV4: IPAddress?
        var firstV6: IPAddress?
        var cur: UnsafeMutablePointer<addrinfo>? = head
        while let ai = cur?.pointee {
            if let sa = ai.ai_addr {
                if ai.ai_family == AF_INET, firstV4 == nil {
                    sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                        var addr = p.pointee.sin_addr
                        let bytes = withUnsafeBytes(of: &addr) { Array($0) }
                        firstV4 = IPAddress(bytes.map(String.init).joined(separator: "."))
                    }
                } else if ai.ai_family == AF_INET6, firstV6 == nil {
                    sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                        var addr = p.pointee.sin6_addr
                        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        if inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil {
                            firstV6 = IPAddress(String(cString: buf))
                        }
                    }
                }
            }
            cur = ai.ai_next
        }
        if let v4 = firstV4 { return v4 }
        if let v6 = firstV6 { return v6 }
        throw TunnelError.resolve(endpoint.host)
    }
}
