import Testing
import Foundation
@testable import WirelyCore

private func parsed(_ s: String) -> SplitRule? {
    if case .success(let r) = SplitRule.parse(s) { return r }
    return nil
}

private func failure(_ s: String) -> SplitRuleError? {
    if case .failure(let e) = SplitRule.parse(s) { return e }
    return nil
}

@Test(arguments: [
    ("example.com", "example.com"),
    ("  Example.COM  ", "example.com"),
    ("https://example.com/path/x?q=1#frag", "example.com"),
    ("http://intranet.example.com:8080/", "intranet.example.com"),
    ("*.example.com", "example.com"),
    ("example.com.", "example.com"),
    ("example.com:443", "example.com"),
    ("example.com/some/path", "example.com"),
    ("https://user@example.com/", "example.com"),
    ("localhost", "localhost"),
    ("10.2.2.4", "10.2.2.4"),
    ("203.0.113.7:443", "203.0.113.7"),
    ("10.2.2.4/32", "10.2.2.4"),
    ("http://198.51.100.9/index.html", "198.51.100.9"),
    ("2001:db8::1", "2001:db8::1"),
    ("[2001:DB8::1]:443", "2001:db8::1"),
    ("2001:db8::1/128", "2001:db8::1"),
    ("10.8.0.0/16", "10.8.0.0/16"),
    ("10.8.0.5/16", "10.8.0.0/16"),
    ("2001:db8:abcd::/48", "2001:db8:abcd::/48"),
    ("0.0.0.0/0", "0.0.0.0/0"),
])
func parseAccepts(input: String, text: String) {
    #expect(parsed(input)?.text == text)
}

@Test func parseKinds() {
    #expect(parsed("example.com") == .domain("example.com"))
    #expect(parsed("10.2.2.4/32") == .address(IPAddress("10.2.2.4")!))
    #expect(parsed("10.8.0.0/16") == .network(IPNetwork("10.8.0.0/16")!))
    #expect(parsed("[2001:db8::1]") == .address(IPAddress("2001:db8::1")!))
}

@Test(arguments: [
    ("", SplitRuleError.notAHost),
    ("   ", .notAHost),
    ("https://", .notAHost),
    ("bad host.com", .notAHost),
    ("-bad.example.com", .notAHost),
    ("exa..mple.com", .notAHost),
    (".example.com", .notAHost),
    ("example.com:abc", .notAHost),
    ("exämple.com", .notAHost),
    ("300.1.1.1", .notAnAddress),
    ("1.2.3", .notAnAddress),
    ("10.0.0.256", .notAnAddress),
    ("12345", .notAnAddress),
    ("10.300.0.0/16", .notAnAddress),
    ("2001:db8::zz", .notAnAddress),
    ("[2001:db8::1", .notAnAddress),
    ("[10.0.0.1]", .notAnAddress),
    ("10.8.0.0/33", .badPrefix),
    ("10.8.0.0/abc", .badPrefix),
    ("10.8.0.0/", .badPrefix),
    ("10.8.0.0/-1", .badPrefix),
    ("2001:db8::/129", .badPrefix),
])
func parseRejects(input: String, error: SplitRuleError) {
    #expect(failure(input) == error)
}

@Test func domainMatchesSubdomainsOnly() {
    let rule = SplitRule.domain("example.com")
    #expect(rule.matches(host: "example.com"))
    #expect(rule.matches(host: "brand.example.com"))
    #expect(rule.matches(host: "A.B.EXAMPLE.COM."))
    #expect(!rule.matches(host: "notexample.com"))
    #expect(!rule.matches(host: "example.com.evil.net"))
    #expect(!SplitRule.address(IPAddress("10.2.2.4")!).matches(host: "10.2.2.4"))
}

@Test func matchingRuleLongestSuffixWins() {
    let rules: [SplitRule] = [.domain("example.com"), .domain("intranet.example.com"),
                              .address(IPAddress("203.0.113.5")!), .domain("other.org")]
    #expect(SplitRule.matchingRule(for: "app.intranet.example.com", in: rules) == .domain("intranet.example.com"))
    #expect(SplitRule.matchingRule(for: "www.example.com", in: rules) == .domain("example.com"))
    #expect(SplitRule.matchingRule(for: "example.net", in: rules) == nil)
    #expect(SplitRule.matchingRule(for: "example.com", in: []) == nil)
}

@Test func splitRuleCodableIsText() throws {
    let rules: [SplitRule] = [.domain("example.com"), .address(IPAddress("10.2.2.4")!),
                              .network(IPNetwork("10.8.0.0/16")!), .address(IPAddress("2001:db8::1")!)]
    let data = try JSONEncoder().encode(rules)
    #expect(String(data: data, encoding: .utf8) == #"["example.com","10.2.2.4","10.8.0.0\/16","2001:db8::1"]"#)
    #expect(try JSONDecoder().decode([SplitRule].self, from: data) == rules)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode([SplitRule].self, from: Data(#"["10.0.0.256"]"#.utf8))
    }
}

// MARK: coverage and targets

private let zeroKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

private func config(allowed: String, dns: String? = nil, tableOff: Bool = false) throws -> TunnelConfig {
    var text = "[Interface]\nPrivateKey = \(zeroKey)\nAddress = 10.8.0.2/32\n"
    if let dns { text += "DNS = \(dns)\n" }
    if tableOff { text += "Table = off\n" }
    text += "[Peer]\nPublicKey = \(zeroKey)\nAllowedIPs = \(allowed)\nEndpoint = 203.0.113.5:51820\n"
    return try TunnelConfig.parse(text)
}

@Test func coverageChecksAllowedIPs() throws {
    let c = try config(allowed: "10.8.0.0/16, 192.0.2.0/24")
    let inside = SplitRule.address(IPAddress("10.8.1.1")!)
    let outside = SplitRule.address(IPAddress("203.0.113.9")!)
    let netInside = SplitRule.network(IPNetwork("10.8.4.0/24")!)
    let netWider = SplitRule.network(IPNetwork("10.0.0.0/8")!)
    let netOutside = SplitRule.network(IPNetwork("198.51.100.0/24")!)
    let rules: [SplitRule] = [inside, outside, netInside, netWider, netOutside, .domain("example.com")]
    #expect(SplitCoverage.uncovered(rules: rules, config: c) == [outside, netWider, netOutside])
    #expect(SplitCoverage.covers(IPAddress("192.0.2.7")!, config: c))
    #expect(!SplitCoverage.covers(IPAddress("2001:db8::1")!, config: c))

    let all = try config(allowed: "0.0.0.0/0")
    #expect(SplitCoverage.uncovered(rules: rules, config: all).isEmpty)
}

@Test func profileNetworksSkipDefaultRoutes() throws {
    let c = try config(allowed: "0.0.0.0/0, ::/0, 10.8.0.0/16, 10.8.0.0/16, fd00::/8")
    #expect(SplitCoverage.profileNetworks(c) == [IPNetwork("10.8.0.0/16")!, IPNetwork("fd00::/8")!])
}

@Test func splitTargetsCombineRulesProfileAndDNS() throws {
    let c = try config(allowed: "0.0.0.0/0, 10.8.0.0/16", dns: "10.8.0.1, fd00::53")
    let rules: [SplitRule] = [.domain("example.com"), .address(IPAddress("10.2.2.4")!),
                              .network(IPNetwork("198.51.100.0/24")!), .address(IPAddress("10.2.2.4")!),
                              .network(IPNetwork("10.8.0.0/16")!)]
    #expect(NetPlan.splitTargets(config: c, rules: rules) == [
        IPNetwork("10.2.2.4/32")!, IPNetwork("198.51.100.0/24")!, IPNetwork("10.8.0.0/16")!,
        IPNetwork("10.8.0.1/32")!, IPNetwork("fd00::53/128")!,
    ])
    let targets = NetPlan.splitTargets(config: c, rules: [])
    #expect(!targets.contains { $0.prefixLength == 0 || $0.prefixLength == 1 })
    #expect(try NetPlan.splitTargets(config: config(allowed: "10.8.0.0/16", tableOff: true), rules: rules) == [])
}

@Test func hostRouteCommands() {
    #expect(NetPlan.hostRouteAdd(IPAddress("198.51.100.9")!, iface: "utun5")
        == NetCommand("/sbin/route", ["-q", "-n", "add", "-inet", "198.51.100.9", "-interface", "utun5"]))
    #expect(NetPlan.hostRouteAdd(IPAddress("2001:db8::9")!, iface: "utun5")
        == NetCommand("/sbin/route", ["-q", "-n", "add", "-inet6", "2001:db8::9", "-interface", "utun5"]))
    #expect(NetPlan.hostRouteDelete(IPAddress("198.51.100.9")!)
        == NetCommand("/sbin/route", ["-q", "-n", "delete", "-inet", "198.51.100.9"]))
    #expect(NetPlan.hostRouteDelete(IPAddress("2001:db8::9")!)
        == NetCommand("/sbin/route", ["-q", "-n", "delete", "-inet6", "2001:db8::9"]))
}
