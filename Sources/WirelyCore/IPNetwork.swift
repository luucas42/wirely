import Foundation

public enum IPFamily: String, Codable { case v4, v6 }

public struct IPAddress: Hashable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    public var family: IPFamily { bytes.count == 4 ? .v4 : .v6 }

    public init?(_ string: String) {
        guard !string.contains("%") else { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, string, &v4) == 1 {
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, string, &v6) == 1 {
            bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        return nil
    }

    public var description: String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let af = family == .v4 ? AF_INET : AF_INET6
        let ok = bytes.withUnsafeBytes { inet_ntop(af, $0.baseAddress, &buf, socklen_t(buf.count)) }
        return ok == nil ? "" : String(cString: buf)
    }
}

public struct IPNetwork: Hashable, Codable, CustomStringConvertible {
    public let address: IPAddress
    public let prefixLength: Int

    public init(address: IPAddress, prefixLength: Int) {
        self.address = address
        self.prefixLength = prefixLength
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let addr = IPAddress(String(parts[0])) else { return nil }
        let maxLen = addr.family == .v4 ? 32 : 128
        var len = maxLen
        if parts.count == 2 {
            guard let n = Int(parts[1]), n >= 0, n <= maxLen,
                  parts[1].allSatisfy(\.isNumber) else { return nil }
            len = n
        }
        self.init(address: addr, prefixLength: len)
    }

    public var description: String { "\(address)/\(prefixLength)" }

    public func contains(_ ip: IPAddress) -> Bool {
        guard ip.family == address.family else { return false }
        var remaining = prefixLength
        for (a, b) in zip(address.bytes, ip.bytes) {
            if remaining <= 0 { break }
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if a & mask != b & mask { return false }
            remaining -= bits
        }
        return true
    }
}

public struct Endpoint: Hashable, Codable, CustomStringConvertible {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public init?(_ string: String) {
        let hostPart: Substring
        let portPart: Substring
        if string.hasPrefix("[") {
            guard let close = string.firstIndex(of: "]") else { return nil }
            hostPart = string[string.index(after: string.startIndex)..<close]
            let rest = string[string.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            portPart = rest.dropFirst()
        } else {
            guard let colon = string.lastIndex(of: ":") else { return nil }
            hostPart = string[..<colon]
            portPart = string[string.index(after: colon)...]
            guard !hostPart.contains(":") else { return nil }
        }
        guard !hostPart.isEmpty, portPart.allSatisfy(\.isASCII), portPart.allSatisfy(\.isNumber),
              let p = UInt16(portPart), p > 0 else { return nil }
        self.init(host: String(hostPart), port: p)
    }

    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
