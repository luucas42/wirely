import Testing
@testable import WirelyCore

@Test func killSwitchRulesConnectedWithLAN() {
    let rules = KillSwitchPlan.rules(iface: "utun7", endpoints: [Endpoint(host: "203.0.113.5", port: 51820)],
                                     allowLAN: true)
    #expect(rules == """
    # Wirely kill switch (generated)
    pass quick on lo0 all flags any keep state
    pass quick on utun7 all flags any keep state
    pass out quick inet proto udp from any to 203.0.113.5 port 51820 keep state
    pass out quick inet proto udp from any to 203.0.113.5 port 33434:34000 keep state
    pass out quick inet proto udp from any port 68 to any port 67 keep state
    pass in quick inet proto udp from any port 67 to any port 68 keep state
    pass out quick inet from any to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 } flags any keep state
    pass in quick inet from { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } to any flags any keep state
    pass out quick inet6 from any to { fe80::/10, ff00::/8 } flags any keep state
    pass in quick inet6 from fe80::/10 to any flags any keep state
    pass in quick inet proto icmp from any to any icmp-type timex
    pass in quick inet proto icmp from any to any icmp-type unreach
    block drop quick all

    """)
}

@Test func killSwitchRulesBlockedWithoutLAN() {
    let rules = KillSwitchPlan.rules(iface: nil, endpoints: [Endpoint(host: "2001:db8::5", port: 443)],
                                     allowLAN: false)
    #expect(!rules.contains("utun"))
    #expect(rules.contains("pass out quick inet6 proto udp from any to 2001:db8::5 port 443 keep state"))
    #expect(!rules.contains("192.168.0.0/16"))
    #expect(!rules.contains("port 53"))
    #expect(rules.hasSuffix("block drop quick all\n"))
}

@Test func killSwitchAllowsTraceProbesOnlyToIPv4Endpoints() {
    let rules = KillSwitchPlan.rules(iface: nil, endpoints: [Endpoint(host: "2001:db8::5", port: 443),
                                                             Endpoint(host: "198.51.100.9", port: 1)],
                                     allowLAN: false)
    #expect(rules.contains("pass out quick inet proto udp from any to 198.51.100.9 port 33434:34000 keep state"))
    #expect(!rules.contains("inet proto udp from any to 2001:db8::5 port 33434"))
    let icmpIn = rules.range(of: "pass in quick inet proto icmp from any to any icmp-type unreach")!
    let block = rules.range(of: "block drop quick all")!
    #expect(icmpIn.upperBound <= block.lowerBound)
}

@Test func killSwitchInterimRulesAllowDNSBeforeTheBlock() throws {
    let rules = KillSwitchPlan.rules(iface: nil, endpoints: [], allowLAN: false, allowDNS: true)
    let dns = try #require(rules.range(of: "pass out quick proto { udp tcp } from any to any port 53 keep state"))
    let block = try #require(rules.range(of: "block drop quick all"))
    #expect(dns.lowerBound < block.lowerBound)
}

@Test func killSwitchSkipsUnresolvedEndpoints() {
    let rules = KillSwitchPlan.rules(iface: "utun7", endpoints: [Endpoint(host: "vpn.example.com", port: 51820)],
                                     allowLAN: false)
    #expect(!rules.contains("vpn.example.com"))
}

@Test func pfctlTokenParsing() {
    #expect(KillSwitchPlan.parseToken("No ALTQ support in kernel\npf enabled\nToken : 7613587937410551407\n")
            == "7613587937410551407")
    #expect(KillSwitchPlan.parseToken("pf already enabled\n") == nil)
    #expect(KillSwitchPlan.load(file: "/x/ks.pf").description == "/sbin/pfctl -a com.apple/250.Wirely -f /x/ks.pf")
    #expect(KillSwitchPlan.release(token: "42").args == ["-X", "42"])
}

@Test func killSwitchTracePortRangeCoversEveryProbePort() {
    let highestSeq = TraceCollector.seq(ttl: 30, round: ProbeSchedule.highestRound())
    #expect(Int(TraceCollector.udpBasePort) + Int(highestSeq) <= Int(KillSwitchPlan.traceLastPort))
}

@Test func splitRulesWithTable() {
    let rules = KillSwitchPlan.splitRules(iface: "utun7", endpoints: [Endpoint(host: "203.0.113.5", port: 51820),
                                                                      Endpoint(host: "vpn.example.com", port: 1)],
                                          table: ["198.51.100.9", "10.8.0.0/16", "2001:db8::1", "198.51.100.9", "bad;entry"])
    #expect(rules == """
    # Wirely kill switch (generated, split)
    table <wirely_split> persist { 198.51.100.9, 10.8.0.0/16, 2001:db8::1 }
    pass quick on lo0 all flags any keep state
    pass quick on utun7 all flags any keep state
    pass out quick inet proto udp from any to 203.0.113.5 port 51820 keep state
    pass out quick inet proto udp from any to 203.0.113.5 port 33434:34000 keep state
    pass out quick inet proto udp from any port 68 to any port 67 keep state
    pass in quick inet proto udp from any port 67 to any port 68 keep state
    block drop out quick to <wirely_split>

    """)
    #expect(!rules.contains("block drop quick all"))
}

@Test func splitRulesEmptyTableAndHeldTunnel() {
    let rules = KillSwitchPlan.splitRules(iface: nil, endpoints: [], table: [])
    #expect(rules.contains("\ntable <wirely_split> persist\n"))
    #expect(!rules.contains("{"))
    #expect(!rules.contains("utun"))
    let tableLine = rules.split(separator: "\n").firstIndex { $0.hasPrefix("table ") }!
    let blockLine = rules.split(separator: "\n").firstIndex { $0.hasPrefix("block ") }!
    #expect(tableLine < blockLine)
}

@Test func splitTableCommands() {
    #expect(KillSwitchPlan.tableAdd(["198.51.100.9", "10.8.0.0/16"]) == NetCommand(
        "/sbin/pfctl", ["-a", "com.apple/250.Wirely", "-t", "wirely_split", "-T", "add", "198.51.100.9", "10.8.0.0/16"]))
    #expect(KillSwitchPlan.tableDelete(["2001:db8::1"]) == NetCommand(
        "/sbin/pfctl", ["-a", "com.apple/250.Wirely", "-t", "wirely_split", "-T", "delete", "2001:db8::1"]))
}
