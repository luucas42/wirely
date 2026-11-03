import Testing
import Foundation
import WirelyCore
@testable import WirelyHelperKit

private let privB64 = "TUs1G5dtbPrNOrSqmV/Hddlk1MMbHw63dD4eIUlODZU="
private let pubB64 = "5eOWMvp44rKHfFuhZU//t2b2q6SblullXT2n4eeapKw="

private func configText(dns: String? = "10.8.0.1", address: String = "10.8.0.2/32",
                        allowed: String = "10.8.0.0/16, 192.0.2.0/24") -> String {
    var s = "[Interface]\nPrivateKey = \(privB64)\nAddress = \(address)\n"
    if let dns { s += "DNS = \(dns)\n" }
    s += "[Peer]\nPublicKey = \(pubB64)\nEndpoint = vpn.example.com:51820\nAllowedIPs = \(allowed)\n"
    return s
}

private func ip(_ s: String) -> IPAddress { IPAddress(s)! }
private func addr(_ s: String) -> SplitRule { .address(ip(s)) }
private func net(_ s: String) -> SplitRule { .network(IPNetwork(s)!) }
private func dom(_ s: String) -> SplitRule { .domain(s) }
private func routeAdd(_ target: String) -> String { "/sbin/route -q -n add -inet \(target) -interface utun7" }
private func routeAdd6(_ target: String) -> String { "/sbin/route -q -n add -inet6 \(target) -interface utun7" }
private let flushCommands = NetPlan.flushDNSCache.map(\.description)

private final class FakeSplitProxy: SplitDNSServing {
    var config: SplitDNSConfig
    let onLearn: (SplitRule, [IPAddress]) -> Void
    var failStart = false
    private(set) var started = false
    private(set) var stopped = false
    private(set) var updates: [SplitDNSConfig] = []
    private(set) var resolved: [String] = []
    var onStop: (() -> Void)?
    var onStart: (() -> Void)?

    init(_ config: SplitDNSConfig, _ onLearn: @escaping (SplitRule, [IPAddress]) -> Void) {
        self.config = config
        self.onLearn = onLearn
    }
    func start() throws {
        if failStart { throw SplitDNSError.portInUse }
        onStart?()
        started = true
    }
    func stop() { stopped = true; onStop?() }
    func update(_ config: SplitDNSConfig) { self.config = config; updates.append(config) }
    func resolveNow(name: String) -> [IPAddress] { resolved.append(name); return [] }
    func learn(_ rule: SplitRule, _ ips: [String]) { onLearn(rule, ips.map(ip)) }
}

private final class FakeNormalDNS: NormalDNSSource {
    var result: [IPAddress] = [IPAddress("192.0.2.53")!]
    private(set) var asked: [[DNSBackup]] = []
    func normalUpstreams(backups: [DNSBackup]) -> [IPAddress] { asked.append(backups); return result }
}

private final class Env {
    let runner = FakeRunner()
    let store = MemoryStore()
    var launchers: [FakeLauncher] = []
    var launcher: FakeLauncher { launchers[launchers.count - 1] }
    var proxies: [FakeSplitProxy] = []
    var failProxyStart = false
    var failSaveOnProxyStart = false
    let normal = FakeNormalDNS()
    let dns = FakeDNSConfigurator([DNSBackup(service: "Wi-Fi", servers: ["192.168.1.1"], searchDomains: ["lan.example.com"]),
                                   DNSBackup(service: "USB LAN", servers: [], searchDomains: [])])
    let firewall = FakeFirewall()
    var manager: TunnelManager!
    var proxy: FakeSplitProxy { proxies[proxies.count - 1] }

    init() {
        runner.script(NetPlan.netstatCommand(.v4),
                      stdout: "Destination Gateway Flags Netif Expire\ndefault 192.168.1.1 UGScg en0\n")
        runner.script(NetPlan.ifconfigShow("en0"), stdout: "en0: flags=8863<UP> mtu 1500\n")
        let r = runner
        manager = TunnelManager(
            runner: r,
            makeLauncher: { [unowned self] in
                let l = FakeLauncher(runner: r)
                self.launchers.append(l)
                return l
            },
            resolver: FakeResolver(table: ["vpn.example.com": "203.0.113.5"]), store: store, dns: dns,
            firewall: firewall, log: { _ in }, now: { Date(timeIntervalSince1970: 1_000) },
            makeSplitProxy: { [unowned self] cfg, hook in
                let p = FakeSplitProxy(cfg, hook)
                p.failStart = self.failProxyStart
                p.onStop = { r.note("proxy.stop") }
                p.onStart = { if self.failSaveOnProxyStart { self.store.failSave = true } }
                self.proxies.append(p)
                return p
            },
            normalDNS: normal,
            background: { $0() })
    }

    @discardableResult
    func up(_ rules: [SplitRule], killSwitch: Bool = false, config: String = configText()) throws -> TunnelStatus {
        try manager.up(name: "home", configText: config, killSwitch: killSwitch, split: rules)
    }
}

@Test func splitUpWithAddressRulesOnly() throws {
    let env = Env()
    let s = try env.up([addr("198.51.100.7"), net("198.51.100.64/26")])
    #expect(s.state == .connected)
    for target in ["198.51.100.7/32", "198.51.100.64/26", "10.8.0.0/16", "192.0.2.0/24", "10.8.0.1/32"] {
        #expect(env.runner.ran(routeAdd(target)), "\(target)")
    }
    #expect(!env.runner.commands.contains { $0.description.contains("0.0.0.0/1") || $0.description.contains("-reject") })
    #expect(env.dns.applied.isEmpty)
    #expect(env.proxies.isEmpty)
    #expect(s.splitDNS == false)
    #expect(s.split == [:])
    let saved = try #require(env.store.state)
    #expect(saved.split == ["198.51.100.7", "198.51.100.64/26"])
    #expect(saved.dnsServers.isEmpty && saved.dnsBackups.isEmpty)
}

@Test func splitUpSkipsUncoveredDNSAndMissingFamily() throws {
    let env = Env()
    _ = try env.up([addr("2001:db8::7"), addr("198.51.100.7")], config: configText(dns: "9.9.9.9"))
    #expect(!env.runner.ran(routeAdd("9.9.9.9/32")))
    #expect(!env.runner.commands.contains { $0.description.contains("2001:db8::7") })
    #expect(env.runner.ran(routeAdd("198.51.100.7/32")))
}

@Test func splitUpWithDomainStartsProxyAndAppliesLocalDNS() throws {
    let env = Env()
    let s = try env.up([dom("example.com"), addr("198.51.100.7")])
    let proxy = env.proxy
    #expect(proxy.started)
    #expect(proxy.config.listed == [DNSUpstream(address: ip("10.8.0.1"))])
    #expect(proxy.config.normal == [DNSUpstream(address: ip("192.0.2.53"))])
    #expect(proxy.config.tunnelIPv6 == false)
    #expect(proxy.config.rules == [dom("example.com"), addr("198.51.100.7")])
    #expect(env.normal.asked.first?.map(\.service) == ["Wi-Fi", "USB LAN"])
    #expect(env.dns.applied.count == 1)
    #expect(env.dns.applied[0].allSatisfy { $0.servers == ["127.0.0.1"] && $0.searchDomains.isEmpty })
    #expect(proxy.resolved == ["example.com"])
    for c in flushCommands { #expect(env.runner.ran(c)) }
    #expect(s.splitDNS == true)
    #expect(s.split == ["example.com": SplitRuleStatus(routed: 0, rejected: 0)])
    let saved = try #require(env.store.state)
    #expect(saved.dnsBackups.map(\.servers) == [["192.168.1.1"], []])
    #expect(saved.dnsServers == [ip("127.0.0.1")] && saved.dnsSearch.isEmpty)

    _ = env.manager.down()
    #expect(env.dns.services.map(\.servers) == [["192.168.1.1"], []])
    #expect(env.dns.services[0].searchDomains == ["lan.example.com"])
}

@Test func proxyFailureKeepsTunnelUpAndDNSUntouched() throws {
    let env = Env()
    env.failProxyStart = true
    let s = try env.up([dom("example.com")])
    #expect(s.state == .connected)
    #expect(s.splitDNS == false)
    #expect(env.dns.applied.isEmpty)
    #expect(env.store.state?.dnsBackups.isEmpty == true)
    #expect(env.proxy.resolved.isEmpty)
    #expect(env.runner.ran(routeAdd("10.8.0.0/16")))
}

@Test func noUsableUpstreamDisablesSiteRules() throws {
    let env = Env()
    env.normal.result = [ip("127.0.0.1")]
    let s = try env.up([dom("example.com")], config: configText(dns: nil))
    #expect(env.proxies.isEmpty)
    #expect(s.splitDNS == false)
    #expect(env.dns.applied.isEmpty)
}

@Test func normalUpstreamsFallBackToProfileDNS() throws {
    let env = Env()
    env.normal.result = [ip("127.0.0.53")]     // loopback only: never used
    _ = try env.up([dom("example.com")])
    #expect(env.proxy.config.normal == [DNSUpstream(address: ip("10.8.0.1"))])
}

@Test func learnHookRoutesOnceAndRejectsUncovered() throws {
    let env = Env()
    _ = try env.up([dom("example.com")])
    env.runner.clearRecorded()
    env.proxy.learn(dom("example.com"), ["10.8.1.5", "10.8.1.5", "198.51.100.9", "192.0.2.9"])
    #expect(env.runner.commands.map(\.description) == [routeAdd("10.8.1.5"), routeAdd("192.0.2.9")])
    env.runner.clearRecorded()
    env.proxy.learn(dom("example.com"), ["10.8.1.5", "198.51.100.9"])
    #expect(env.runner.commands.isEmpty)
    #expect(env.manager.status().split == ["example.com": SplitRuleStatus(routed: 2, rejected: 1)])
}

@Test func learnHookAddsPfTableEntriesWithKillSwitch() throws {
    let env = Env()
    _ = try env.up([dom("example.com")], killSwitch: true)
    env.runner.clearRecorded()
    env.proxy.learn(dom("example.com"), ["10.8.1.5", "10.8.1.5", "10.8.1.6"])
    #expect(env.runner.commands.contains(KillSwitchPlan.tableAdd(["10.8.1.5", "10.8.1.6"])))
    #expect(env.runner.commands.filter { $0.description.contains("-T add") }.count == 1)
    env.runner.clearRecorded()
    env.proxy.learn(dom("example.com"), ["10.8.1.5"])
    #expect(env.runner.commands.isEmpty)
}

@Test func splitKillSwitchRulesBeforeAndAfterLauncher() throws {
    let env = Env()
    _ = try env.up([addr("198.51.100.7"), dom("example.com")], killSwitch: true)
    #expect(env.firewall.loaded.count == 2)
    let first = env.firewall.loaded[0]
    #expect(first.contains("table <wirely_split> persist { 198.51.100.7, 10.8.0.0/16, 192.0.2.0/24 }"))
    #expect(!first.contains("utun7"))
    #expect(first.contains("pass out quick inet proto udp from any to 203.0.113.5 port 51820 keep state"))
    #expect(env.firewall.loaded[1].contains("pass quick on utun7 all flags any keep state"))
    #expect(!env.firewall.loaded.contains { $0.contains("block drop quick all") })
    #expect(env.store.state?.killSwitch?.splitTable == ["198.51.100.7", "10.8.0.0/16", "192.0.2.0/24"])
}

@Test func updateSplitDiffsAddressesAndNetworks() throws {
    let env = Env()
    _ = try env.up([addr("198.51.100.7"), net("198.51.100.64/26")], killSwitch: true)
    env.runner.clearRecorded()
    let s = try env.manager.updateSplit([addr("198.51.100.8"), net("198.51.100.64/26")])
    #expect(s.state == .connected)
    let cmds = env.runner.commands.map(\.description)
    #expect(cmds.contains("/sbin/route -q -n delete -inet 198.51.100.7/32"))
    #expect(cmds.contains(routeAdd("198.51.100.8/32")))
    #expect(!cmds.contains { $0.contains("198.51.100.64/26") })
    #expect(env.runner.commands.contains(KillSwitchPlan.tableDelete(["198.51.100.7"])))
    #expect(env.runner.commands.contains(KillSwitchPlan.tableAdd(["198.51.100.8"])))
    #expect(env.proxies.isEmpty)
    let saved = try #require(env.store.state)
    #expect(saved.split == ["198.51.100.8", "198.51.100.64/26"])
    #expect(saved.killSwitch?.splitTable == ["198.51.100.8", "198.51.100.64/26", "10.8.0.0/16", "192.0.2.0/24"])
}

@Test func updateSplitKeepsRoutesSharedWithProfile() throws {
    let env = Env()
    _ = try env.up([net("10.8.0.0/16"), addr("198.51.100.7")], killSwitch: true)
    env.runner.clearRecorded()
    _ = try env.manager.updateSplit([addr("198.51.100.7")])
    #expect(!env.runner.commands.contains { $0.description.contains("delete") })
    // The profile network stays blocked in pf although its rule is gone.
    #expect(!env.runner.commands.contains { $0.description.contains("-T delete") })
    #expect(env.store.state?.killSwitch?.splitTable == ["198.51.100.7", "10.8.0.0/16", "192.0.2.0/24"])
}

@Test func updateSplitDomainsAddRemove() throws {
    let env = Env()
    _ = try env.up([dom("example.com"), dom("example.net")], killSwitch: true)
    let proxy = env.proxy
    proxy.learn(dom("example.net"), ["10.8.1.5"])
    proxy.learn(dom("example.com"), ["10.8.1.5", "10.8.1.6"])
    env.runner.clearRecorded()

    // Remove example.net (shares 10.8.1.5 with example.com), add intranet.example.com.
    _ = try env.manager.updateSplit([dom("example.com"), dom("intranet.example.com")])
    #expect(proxy.updates.count == 1)
    #expect(proxy.updates[0].rules == [dom("example.com"), dom("intranet.example.com")])
    #expect(proxy.resolved.suffix(1) == ["intranet.example.com"])
    #expect(env.runner.commands.isEmpty == false)
    #expect(!env.runner.commands.contains { $0.description.contains("delete") })   // nothing exclusively owned
    for c in flushCommands { #expect(env.runner.ran(c)) }

    // Remove example.com too: its two addresses are now exclusively owned by nobody else.
    env.runner.clearRecorded()
    _ = try env.manager.updateSplit([dom("intranet.example.com")])
    #expect(env.runner.ran("/sbin/route -q -n delete -inet 10.8.1.5"))
    #expect(env.runner.ran("/sbin/route -q -n delete -inet 10.8.1.6"))
    #expect(env.runner.commands.contains(KillSwitchPlan.tableDelete(["10.8.1.5", "10.8.1.6"])))
    #expect(env.manager.status().split?.keys.sorted() == ["intranet.example.com"])
}

@Test func updateSplitStartsAndStopsDNSWithFirstAndLastDomain() throws {
    let env = Env()
    _ = try env.up([addr("198.51.100.7")])
    #expect(env.proxies.isEmpty)

    let s = try env.manager.updateSplit([addr("198.51.100.7"), dom("example.com")])    // 0 -> 1
    #expect(env.proxies.count == 1 && env.proxy.started)
    #expect(s.splitDNS == true)
    #expect(env.dns.applied.count == 1)
    #expect(env.dns.applied[0].allSatisfy { $0.servers == ["127.0.0.1"] })
    #expect(env.proxy.resolved == ["example.com"])
    #expect(env.store.state?.dnsServers == [ip("127.0.0.1")])

    env.proxy.learn(dom("example.com"), ["10.8.1.5"])
    env.runner.clearRecorded()
    let s2 = try env.manager.updateSplit([addr("198.51.100.7")])                        // 1 -> 0
    let events = env.runner.events
    #expect(env.proxy.stopped)
    #expect(s2.splitDNS == false)
    #expect(env.dns.applied.count == 2)
    #expect(env.dns.services.map(\.servers) == [["192.168.1.1"], []])
    #expect(env.dns.services[0].searchDomains == ["lan.example.com"])
    #expect(env.runner.ran("/sbin/route -q -n delete -inet 10.8.1.5"))
    #expect(events.contains("proxy.stop"))
    #expect(env.store.state?.dnsBackups.isEmpty == true && env.store.state?.dnsServers.isEmpty == true)

    _ = try env.manager.updateSplit([addr("198.51.100.7"), dom("example.com")])         // and back: second proxy
    #expect(env.proxies.count == 2 && env.proxy.started)
}

@Test func updateSplitOutsideSplitModeFails() throws {
    let env = Env()
    #expect(throws: TunnelError.splitNotActive) { try env.manager.updateSplit([dom("example.com")]) }
    _ = try env.manager.up(name: "home", configText: configText(allowed: "0.0.0.0/0"))
    #expect(throws: TunnelError.splitNotActive) { try env.manager.updateSplit([dom("example.com")]) }
    #expect(TunnelError.splitNotActive.codeAndArg.code == "split.notActive")
    let status = env.manager.status()
    #expect(status.split == nil && status.splitDNS == nil)
}

@Test func teardownStopsProxyBeforeRestoringDNS() throws {
    let env = Env()
    _ = try env.up([dom("example.com")])
    env.dns.onApply = { [runner = env.runner] _ in runner.note("dns.apply") }
    env.runner.clearRecorded()
    _ = env.manager.down()
    let events = env.runner.events
    let stop = try #require(events.firstIndex(of: "proxy.stop"))
    let restore = try #require(events.firstIndex(of: "dns.apply"))
    #expect(stop < restore)
    #expect(stop < (try #require(events.firstIndex(of: "launcher.stop"))))
    #expect(!env.runner.commands.contains { $0.description.contains("10.8.1.5") })
}

@Test func failedSplitUpRollsBack() throws {
    let env = Env()
    env.runner.fail(NetCommand("/sbin/ifconfig", ["utun7", "up"]))
    #expect(throws: TunnelError.self) { try env.up([dom("example.com")]) }
    #expect(env.proxies.isEmpty)           // never got that far
    #expect(env.launcher.stopped)
    #expect(env.store.state == nil)
}

@Test func stateSaveFailureAfterProxyStartStopsProxyAndLeavesDNS() throws {
    let env = Env()
    env.failSaveOnProxyStart = true
    #expect(throws: TunnelError.self) { try env.up([dom("example.com")]) }
    #expect(env.proxy.stopped)
    #expect(env.launcher.stopped)
    // Only the rollback's restore of the untouched originals; 127.0.0.1 was never applied.
    #expect(env.dns.applied.flatMap { $0 }.allSatisfy { $0.servers != ["127.0.0.1"] })
    #expect(env.dns.services.map(\.servers) == [["192.168.1.1"], []])
    #expect(env.manager.status() == .disconnected)
}

@Test func dropInSplitModeHoldsWithLearnedTable() throws {
    let env = Env()
    _ = try env.up([addr("198.51.100.7"), dom("example.com")], killSwitch: true)
    env.proxy.learn(dom("example.com"), ["10.8.1.5"])
    env.launcher.simulateExit()

    #expect(env.proxy.stopped)
    let held = try #require(env.firewall.current)
    #expect(held.contains("table <wirely_split> persist { 198.51.100.7, 10.8.0.0/16, 192.0.2.0/24, 10.8.1.5 }"))
    #expect(held.contains("block drop out quick to <wirely_split>"))
    #expect(!held.contains("block drop quick all"))
    #expect(!held.contains("utun7"))
    let status = env.manager.status()
    #expect(status.state == .failed && status.killSwitch == true)
    #expect(env.store.state?.killSwitch?.splitTable == ["198.51.100.7", "10.8.0.0/16", "192.0.2.0/24", "10.8.1.5"])
    #expect(env.dns.services.map(\.servers) == [["192.168.1.1"], []])    // DNS restored on drop

    // "Allow internet" releases it.
    _ = env.manager.down()
    #expect(env.firewall.current == nil)
}

@Test func staleSplitRecordKeepsBlockingTheTable() throws {
    let env = Env()
    _ = try env.up([addr("198.51.100.7")], killSwitch: true)
    let state = try #require(env.store.state)
    let fresh = Env()
    fresh.store.state = state
    _ = try fresh.firewall.engage(rules: "# old", token: state.killSwitch?.token)
    fresh.manager.cleanupStale()
    #expect(fresh.firewall.current?.contains("table <wirely_split> persist { 198.51.100.7, 10.8.0.0/16, 192.0.2.0/24 }") == true)
    #expect(fresh.firewall.current?.contains("block drop quick all") == false)
}

@Test func networkChangeUpdatesProxyUpstreams() throws {
    let env = Env()
    _ = try env.up([dom("example.com")])
    #expect(env.proxy.updates.isEmpty)
    env.normal.result = [ip("198.51.100.53")]
    env.dns.onApply = { _ in Issue.record("DNS must not be re-applied when nothing changed") }
    env.manager.networkChanged()
    #expect(env.proxy.updates.count == 1)
    #expect(env.proxy.updates[0].normal == [DNSUpstream(address: ip("198.51.100.53"))])
    #expect(env.proxy.updates[0].listed == [DNSUpstream(address: ip("10.8.0.1"))])
    // The backups handed to the source are the originals, not our own 127.0.0.1.
    #expect(env.normal.asked.last?.first?.servers == ["192.168.1.1"])
}

@Test func persistedStateSplitDecodesWhenMissing() throws {
    let json = """
    {"tunnelName":"home","interface":"utun5","endpointRoutes":[],"dnsBackups":[],"dnsServers":[],"dnsSearch":[],
     "connectedAt":0,"ignoredKeys":[]}
    """
    let old = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
    #expect(old.split == nil)
    var state = old
    state.split = ["example.com", "10.8.0.0/16"]
    #expect(try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state)) == state)
}

@Test func profileNetworksStayBlockedButDNSServersDoNot() throws {
    let env = Env()
    _ = try env.up([], killSwitch: true)
    let table = try #require(env.store.state?.killSwitch?.splitTable)
    #expect(table == ["10.8.0.0/16", "192.0.2.0/24"])
    #expect(!table.contains("10.8.0.1") && !table.contains("10.8.0.1/32"))
}

@Test func failedReconnectWhileBlockingKeepsSplitTable() throws {
    let env = Env()
    _ = try env.up([addr("198.51.100.7")], killSwitch: true)
    env.launcher.simulateExit()
    env.runner.fail(NetCommand("/sbin/ifconfig", ["utun7", "up"]))
    #expect(throws: TunnelError.self) { try env.up([addr("198.51.100.7")], killSwitch: true) }
    let held = try #require(env.firewall.current)
    #expect(held.contains("table <wirely_split> persist { 198.51.100.7, 10.8.0.0/16, 192.0.2.0/24 }"))
    #expect(!held.contains("block drop quick all"))
    #expect(env.store.state?.killSwitch?.splitTable == ["198.51.100.7", "10.8.0.0/16", "192.0.2.0/24"])
}
