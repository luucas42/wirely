import Foundation

public enum SplitRuleError: Error, Equatable {
    /// Looks like an IP address or network but isn't one (bad octet, too few octets, zone id…).
    case notAnAddress
    /// A CIDR suffix that is not a number in range for the address family.
    case badPrefix
    /// Not a usable host name (empty, bad characters, bad label length).
    case notAHost
}

/// One entry of a profile's "only selected" list.
public enum SplitRule: Hashable, Codable {
    case domain(String)
    case address(IPAddress)
    case network(IPNetwork)

    /// Canonical string used on the wire and in storage.
    public var text: String {
        switch self {
        case .domain(let d): return d
        case .address(let a): return a.description
        case .network(let n): return n.description
        }
    }

    /// Accepts what people paste: URLs, `*.example.com`, `host:443`, `[2001:db8::1]:443`, `10.8.0.0/16`.
    public static func parse(_ input: String) -> Result<SplitRule, SplitRuleError> {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hadScheme = false
        if let r = s.range(of: "://") {
            s = String(s[r.upperBound...])
            hadScheme = true
        }
        if let i = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<i]) }
        var head = s
        var tail: String?
        if let i = s.firstIndex(of: "/") {
            head = String(s[..<i])
            tail = String(s[s.index(after: i)...])
        }
        if let at = head.lastIndex(of: "@") { head = String(head[head.index(after: at)...]) }

        if !hadScheme, let tail, looksLikeAddress(head) {
            return parseNetwork(head, prefix: tail.split(separator: "/", maxSplits: 1,
                                                          omittingEmptySubsequences: false).first.map(String.init) ?? "")
        }

        var host = head
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return .failure(.notAnAddress) }
            let inner = String(host[host.index(after: host.startIndex)..<close])
            let rest = host[host.index(after: close)...]
            guard rest.isEmpty || (rest.hasPrefix(":") && rest.dropFirst().allSatisfy(\.isASCIIDigit)) else {
                return .failure(.notAnAddress)
            }
            guard let a = IPAddress(inner), a.family == .v6 else { return .failure(.notAnAddress) }
            return .success(.address(a))
        }
        let colons = host.filter { $0 == ":" }.count
        if colons >= 2 {
            guard let a = IPAddress(host) else { return .failure(.notAnAddress) }
            return .success(.address(a))
        }
        if colons == 1 {
            let i = host.firstIndex(of: ":")!
            let port = host[host.index(after: i)...]
            guard !port.isEmpty, port.allSatisfy(\.isASCIIDigit) else { return .failure(.notAHost) }
            host = String(host[..<i])
        }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        while host.hasSuffix(".") { host.removeLast() }

        if looksLikeAddress(host) {
            guard let a = IPAddress(host), a.family == .v4 else { return .failure(.notAnAddress) }
            return .success(.address(a))
        }
        guard isValidHostName(host) else { return .failure(.notAHost) }
        return .success(.domain(host))
    }

    private static func parseNetwork(_ addr: String, prefix: String) -> Result<SplitRule, SplitRuleError> {
        guard let a = IPAddress(addr) else { return .failure(.notAnAddress) }
        let maxLen = a.family == .v4 ? 32 : 128
        guard !prefix.isEmpty, prefix.allSatisfy(\.isASCIIDigit), let n = Int(prefix), n <= maxLen else {
            return .failure(.badPrefix)
        }
        if n == maxLen { return .success(.address(a)) }
        return .success(.network(IPNetwork(address: masked(a, prefix: n), prefixLength: n)))
    }

    /// Clears the host bits so `10.8.0.5/16` and `10.8.0.0/16` are the same rule.
    private static func masked(_ a: IPAddress, prefix: Int) -> IPAddress {
        var bytes = a.bytes
        var remaining = prefix
        for i in bytes.indices {
            let bits = max(0, min(8, remaining))
            bytes[i] &= UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            remaining -= 8
        }
        let text: String
        if bytes.count == 4 {
            text = bytes.map(String.init).joined(separator: ".")
        } else {
            text = stride(from: 0, to: 16, by: 2).map { String(format: "%x", Int(bytes[$0]) << 8 | Int(bytes[$0 + 1])) }
                .joined(separator: ":")
        }
        return IPAddress(text) ?? a
    }

    /// Digits and dots only (a mistyped IPv4), or a colon/hex string (IPv6): never a host name.
    private static func looksLikeAddress(_ s: String) -> Bool {
        if s.isEmpty { return false }
        if s.allSatisfy({ $0.isASCIIDigit || $0 == "." }) { return true }
        return s.filter({ $0 == ":" }).count >= 2 && s.allSatisfy { $0.isASCIIDigit || $0 == ":" || $0 == "." || ("a"..."f").contains($0) }
    }

    private static func isValidHostName(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 253 else { return false }
        for label in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.utf8.count <= 63,
                  !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isASCIIDigit || $0 == "-" || $0 == "_") })
            else { return false }
        }
        return true
    }

    /// Domain rules only: the name itself and every subdomain.
    public func matches(host: String) -> Bool {
        guard case .domain(let d) = self else { return false }
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h == d || h.hasSuffix("." + d)
    }

    /// The most specific (longest) domain rule that covers `name`.
    public static func matchingRule(for name: String, in rules: [SplitRule]) -> SplitRule? {
        var best: SplitRule?
        var bestLen = -1
        for rule in rules {
            guard case .domain(let d) = rule, rule.matches(host: name), d.count > bestLen else { continue }
            best = rule
            bestLen = d.count
        }
        return best
    }

    // MARK: Codable (as the canonical text)

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        switch SplitRule.parse(text) {
        case .success(let rule): self = rule
        case .failure:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid split rule: \(text)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
