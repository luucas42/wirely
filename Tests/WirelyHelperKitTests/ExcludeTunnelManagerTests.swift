import Testing
import Foundation
import WirelyCore
@testable import WirelyHelperKit

private let privB64 = "TUs1G5dtbPrNOrSqmV/Hddlk1MMbHw63dD4eIUlODZU="
private let pubB64 = "5eOWMvp44rKHfFuhZU//t2b2q6SblullXT2n4eeapKw="

private func configText(dns: String? = "10.8.0.1", allowed: String = "0.0.0.0/0, ::/0, 10.8.0.0/16") -> String {
    var s = "[Interface]\nPrivateKey = \(privB64)\nAddress = 10.8.0.2/32\n"
    if let dns { s += "DNS = \(dns)\n" }
    s += "[Peer]\nPublicKey = \(pubB64)\nEndpoint = vpn.example.com:51820\nAllowedIPs = \(allowed)\n"
    return s
}

private func ip(_ s: String) -> IPAddress { IPAddress(s)! }
private func net(_ s: String) -> IPNetwork { IPNetwork(s)! }
private func addr(_ s: String) -> SplitRule { .address(ip(s)) }
private func netRule(_ s: String) -> SplitRule { .network(net(s)) }
private func bypass(_ target: String) -> String { "/sbin/route -q -n add -inet \(target) -gateway 192.168.1.1" }
private func del(_ target: String) -> String { "/sbin/route -q -n delete -inet \(target)" }

private final class Env {
    let runner = FakeRunner()
    let store = MemoryStore()
    var launchers: [FakeLauncher] = []
    var launcher: FakeLauncher { launchers[launchers.count - 1] }
    let dns = FakeDNSConfigurator([DNSBackup(service: "Wi-Fi", servers: ["192.168.1.1"], searchDomains: [])])
    let firewall = FakeFirewall()
    let ledgerPath = NSTemporaryDirectory() + "wirely-test-\(UUID().uuidString)/bypass.json"
    var ledger: BypassLedger
    var manager: TunnelManager!

    init(ifconfig: String = "en0: flags=8863<UP> mtu 1500\n\tinet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255\n") {
        runner.script(NetPlan.netstatCommand(.v4),
                      stdout: "Destination Gateway Flags Netif Expire\ndefault 192.168.1.1 UGScg en0\n")
        runner.script(NetPlan.ifconfigShow("en0"), stdout: ifconfig)
        ledger = BypassLedger(path: ledgerPath)
        manager = makeManager()
    }

    deinit { try? FileManager.default.removeItem(atPath: (ledgerPath as NSString).deletingLastPathComponent) }

    func makeManager() -> TunnelManager {
        let r = runner
        return TunnelManager(
            runner: r,
            makeLauncher: { [unowned self] in
                let l = FakeLauncher(runner: r)
                self.launchers.append(l)
                return l
            },
            resolver: FakeResolver(table: ["vpn.example.com": "203.0.113.5"]), store: store, dns: dns,
            firewall: firewall, log: { _ in }, now: { Date(timeIntervalSince1970: 1_000) },
            makeSplitProxy: { _, _ in fatalError("no DNS proxy in exclude mode yet") },
            background: { $0() },
            ledger: BypassLedger(path: ledgerPath))
    }

    @discardableResult
    func up(_ rules: [SplitRule], killSwitch: Bool = false, config: String = configText()) throws -> TunnelStatus {
        try manager.up(name: "home", configText: config, killSwitch: killSwitch, split: rules, splitExclude: true)
    }

    var ledgerOnDisk: [String] {
        guard let d = FileManager.default.contents(atPath: ledgerPath) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: d)) ?? []
    }
}

// MARK: - BypassLedger

@Test func ledgerRoundTripAndFileMode() throws {
    let env = Env()
    let l = BypassLedger(path: env.ledgerPath)
    try l.add([net("198.51.100.7/32"), net("198.51.100.64/26"), net("198.51.100.7/32")])
    #expect(l.all == [net("198.51.100.7/32"), net("198.51.100.64/26")])
    #expect(env.ledgerOnDisk == ["198.51.100.7/32", "198.51.100.64/26"])
    let attrs = try FileManager.default.attributesOfItem(atPath: env.ledgerPath)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
    let dir = (env.ledgerPath as NSString).deletingLastPathComponent
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["bypass.json"])   // no temp file left
    #expect(BypassLedger(path: env.ledgerPath).all == l.all)   // a new process sees it
}

@Test func ledgerRemoveAndClear() throws {
    let env = Env()
    let l = BypassLedger(path: env.ledgerPath)
    try l.add([net("198.51.100.7/32"), net("198.51.100.64/26")])
    l.remove([net("198.51.100.7/32")])
    #expect(l.all == [net("198.51.100.64/26")])
    #expect(env.ledgerOnDisk == ["198.51.100.64/26"])
    l.clear()
    #expect(l.all.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: env.ledgerPath))
}

@Test func ledgerIgnoresCorruptFile() throws {
    let env = Env()
    try FileManager.default.createDirectory(atPath: (env.ledgerPath as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    try Data("nonsense".utf8).write(to: URL(fileURLWithPath: env.ledgerPath))
    #expect(BypassLedger(path: env.ledgerPath).all.isEmpty)
}

@Test func ledgerConcurrentAdds() throws {
    let env = Env()
    let l = BypassLedger(path: env.ledgerPath)
    DispatchQueue.concurrentPerform(iterations: 40) { i in
        try? l.add([net("198.51.100.\(i + 1)/32")])
    }
    #expect(l.all.count == 40)
    #expect(BypassLedger(path: env.ledgerPath).all.count == 40)
}

// MARK: - exclude up

@Test func excludeUpRoutesEverythingAndBypassesTheList() throws {
    let env = Env()
    let s = try env.up([addr("198.51.100.7"), netRule("198.51.100.64/26"), .domain("example.com")])
    #expect(s.state == .connected)
    #expect(s.splitExclude == true)
    #expect(s.splitDNS == false)
    for t in ["0.0.0.0/1", "128.0.0.0/1", "10.8.0.0/16"] {
        #expect(env.runner.ran("/sbin/route -q -n add -inet \(t) -interface utun7"), "\(t)")
    }
    #expect(env.runner.ran("/sbin/route -q -n add -inet6 ::/1 127.0.0.1 -reject".replacingOccurrences(of: "127.0.0.1", with: "::1")))
    #expect(env.runner.ran(bypass("198.51.100.7")))
    #expect(env.runner.ran(bypass("198.51.100.64/26")))
    // The tunnel endpoint keeps its own gateway route.
    #expect(env.runner.ran("/sbin/route -q -n add -inet 203.0.113.5 -gateway 192.168.1.1"))
    #expect(env.ledger.all.isEmpty)   // the test ledger object is separate; the manager's file is the truth
    #expect(env.ledgerOnDisk == ["198.51.100.7/32", "198.51.100.64/26"])
    let saved = try #require(env.store.state)
    #expect(saved.split == ["198.51.100.7", "198.51.100.64/26", "example.com"])
}

@Test func excludeUpAppliesFullTunnelDNS() throws {
    let env = Env()
    try env.up([addr("198.51.100.7"), .domain("example.com")])
    #expect(env.dns.applied.count == 1)
    #expect(env.dns.applied[0].allSatisfy { $0.servers == ["10.8.0.1"] })
    let saved = try #require(env.store.state)
    #expect(saved.dnsServers == [ip("10.8.0.1")])
    #expect(saved.dnsBackups.map(\.service) == ["Wi-Fi"])
}

@Test func excludeUpWithoutProfileDNSLeavesDNSAlone() throws {
    let env = Env()
    try env.up([addr("198.51.100.7")], config: configText(dns: nil))
    #expect(env.dns.applied.isEmpty)
}

@Test func excludeUpSkipsEndpointLoopbackLinkLocalProfileAndConnectedSubnet() throws {
    let env = Env()
    try env.up([addr("203.0.113.5"), addr("127.0.0.5"), addr("169.254.7.7"), addr("10.8.5.5"),
                netRule("10.8.9.0/24"), addr("192.168.1.77"), netRule("192.168.1.128/25"),
                addr("2001:db8::7"), addr("198.51.100.9")])
    let bypassAdds = env.runner.commands.filter { $0.description.contains("-gateway") }.map(\.description)
    // Only the endpoint's own route and the one real bypass route.
    #expect(Set(bypassAdds) == [bypass("203.0.113.5"), bypass("198.51.100.9")])
    #expect(env.ledgerOnDisk == ["198.51.100.9/32"])
    #expect(!env.runner.commands.contains { $0.description.contains("2001:db8::7") })
}

@Test func excludeUpKeepsCoveringNetworkAroundConnectedSubnet() throws {
    // A rule network wider than the connected subnet is still routed (the connected route is more specific).
    let env = Env()
    try env.up([netRule("192.168.0.0/16")])
    #expect(env.runner.ran(bypass("192.168.0.0/16")))
}

@Test func excludeUpWithoutPhysicalInterfaceInfoSkipsNoSubnet() throws {
    let env = Env(ifconfig: "en0: flags=8863<UP> mtu 1500\n")
    try env.up([addr("192.168.1.77")])
    #expect(env.runner.ran(bypass("192.168.1.77")))
}

@Test func excludeUpLoadsExcludeRulesWithTable() throws {
    let env = Env()
    try env.up([addr("198.51.100.7"), netRule("198.51.100.64/26"), addr("2001:db8::7"), .domain("example.com")],
               killSwitch: true)
    let rules = try #require(env.firewall.current)
    #expect(rules.contains("table <wirely_split> persist { 198.51.100.7, 198.51.100.64/26 }"))
    #expect(rules.contains("pass out quick to <wirely_split> flags any keep state"))
    #expect(rules.contains("pass quick on utun7 all flags any keep state"))
    #expect(rules.hasSuffix("block drop quick all\n"))
    let k = try #require(env.store.state?.killSwitch)
    #expect(k.splitExclude == true)
    #expect(k.splitTable == ["198.51.100.7", "198.51.100.64/26"])
    #expect(env.firewall.loaded.first?.contains("pass quick on utun7") == false)   // armed before the tunnel
}

@Test func includeUpDoesNotMarkExclude() throws {
    let env = Env()
    let s = try env.manager.up(name: "home", configText: configText(allowed: "10.8.0.0/16"), split: [addr("198.51.100.7")])
    #expect(s.splitExclude == false)
    #expect(env.ledgerOnDisk.isEmpty)
    #expect(!env.runner.commands.contains { $0.description.contains("-gateway 192.168.1.1") && !$0.description.contains("203.0.113.5") })
}

// MARK: - teardown, cleanup, hold

@Test func downDeletesEveryLedgerRoute() throws {
    let env = Env()
    try env.up([addr("198.51.100.7"), netRule("198.51.100.64/26")])
    env.runner.clearRecorded()
    env.manager.down()
    #expect(env.runner.ran(del("198.51.100.7")))
    #expect(env.runner.ran(del("198.51.100.64/26")))
    #expect(env.ledgerOnDisk.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: env.ledgerPath))
}

@Test func reconnectInFullModeLeavesNoBypassRoutes() throws {
    let env = Env()
    try env.up([addr("198.51.100.7")])
    env.runner.clearRecorded()
    _ = try env.manager.up(name: "home", configText: configText())
    #expect(env.runner.ran(del("198.51.100.7")))
    #expect(env.ledgerOnDisk.isEmpty)
}

@Test func failedExcludeUpRollsBackBypassRoutes() throws {
    let env = Env()
    env.runner.fail(NetCommand("/sbin/route", ["-q", "-n", "add", "-inet", "128.0.0.0/1", "-interface", "utun7"]))
    #expect(throws: (any Error).self) { try env.up([addr("198.51.100.7")]) }
    #expect(env.ledgerOnDisk.isEmpty)
}

@Test func cleanupStaleDeletesLedgerRoutesAfterACrash() throws {
    let env = Env()
    try env.up([addr("198.51.100.7"), netRule("198.51.100.64/26")])
    // The helper "restarts": a new manager over the same state file and ledger file.
    let fresh = env.makeManager()
    env.runner.clearRecorded()
    fresh.cleanupStale()
    #expect(env.runner.ran(del("198.51.100.7")))
    #expect(env.runner.ran(del("198.51.100.64/26")))
    #expect(env.ledgerOnDisk.isEmpty)
    #expect(env.store.state == nil)
}

@Test func cleanupStaleWithOnlyALedgerStillDeletesRoutes() throws {
    let env = Env()
    try BypassLedger(path: env.ledgerPath).add([net("198.51.100.7/32")])
    env.makeManager().cleanupStale()
    #expect(env.runner.ran(del("198.51.100.7")))
    #expect(env.ledgerOnDisk.isEmpty)
}

@Test func holdInExcludeModeKeepsTheTable() throws {
    let env = Env()
    try env.up([addr("198.51.100.7")], killSwitch: true)
    env.launcher.simulateExit()
    let rules = try #require(env.firewall.current)
    #expect(rules.contains("table <wirely_split> persist { 198.51.100.7 }"))
    #expect(rules.contains("pass out quick to <wirely_split> flags any keep state"))
    #expect(!rules.contains("pass quick on utun7"))
    #expect(rules.hasSuffix("block drop quick all\n"))
    let held = try #require(env.store.state?.killSwitch)
    #expect(held.splitExclude == true)
    #expect(held.splitTable == ["198.51.100.7"])
    #expect(env.ledgerOnDisk.isEmpty)   // bypass routes are removed on a drop; the table keeps the sites reachable
}

@Test func cleanupStaleHoldKeepsExcludeRules() throws {
    let env = Env()
    try env.up([addr("198.51.100.7")], killSwitch: true)
    env.makeManager().cleanupStale()
    let rules = try #require(env.firewall.current)
    #expect(rules.contains("pass out quick to <wirely_split>"))
    #expect(!rules.contains("pass quick on utun7"))
}

@Test func reconnectWhileBlockingInExcludeModeKeepsExcludeRulesForHostnameLookup() throws {
    let env = Env()
    try env.up([addr("198.51.100.7")], killSwitch: true)
    env.launcher.simulateExit()
    env.firewall.onEngage = nil
    _ = try env.up([addr("198.51.100.7")], killSwitch: true)
    // The lookup window (hostname endpoint while blocking) is an exclude ruleset with DNS allowed.
    #expect(env.firewall.loaded.contains {
        $0.contains("pass out quick to <wirely_split>") && $0.contains("port 53")
    })
}

// MARK: - live rule changes

@Test func updateSplitAddsAndRemovesBypassRoutes() throws {
    let env = Env()
    try env.up([addr("198.51.100.7")], killSwitch: true)
    env.runner.clearRecorded()
    let s = try env.manager.updateSplit([netRule("198.51.100.64/26"), addr("203.0.113.9"), addr("192.168.1.55")])
    #expect(s.splitExclude == true)
    #expect(env.runner.ran(del("198.51.100.7")))
    #expect(env.runner.ran(bypass("198.51.100.64/26")))
    #expect(env.runner.ran(bypass("203.0.113.9")))
    #expect(!env.runner.ran(bypass("192.168.1.55")))   // connected subnet
    #expect(env.ledgerOnDisk == ["198.51.100.64/26", "203.0.113.9/32"])
    #expect(env.runner.ran(KillSwitchPlan.tableDelete(["198.51.100.7"]).description))
    #expect(env.runner.ran(KillSwitchPlan.tableAdd(["198.51.100.64/26", "203.0.113.9", "192.168.1.55"]).description))
    let saved = try #require(env.store.state)
    #expect(saved.split == ["198.51.100.64/26", "203.0.113.9", "192.168.1.55"])
    #expect(saved.killSwitch?.splitTable == ["198.51.100.64/26", "203.0.113.9", "192.168.1.55"])
    // Keeping a rule does not touch its route.
    env.runner.clearRecorded()
    _ = try env.manager.updateSplit([netRule("198.51.100.64/26")])
    #expect(!env.runner.ran(bypass("198.51.100.64/26")))
    #expect(env.runner.ran(del("203.0.113.9")))
    #expect(env.ledgerOnDisk == ["198.51.100.64/26"])
}

@Test func updateSplitInExcludeModeIsRejectedWhenNotActive() throws {
    let env = Env()
    #expect(throws: TunnelError.self) { try env.manager.updateSplit([addr("198.51.100.7")]) }
}
