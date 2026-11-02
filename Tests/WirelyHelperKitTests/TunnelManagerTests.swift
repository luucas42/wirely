import Testing
import Foundation
import WirelyCore
@testable import WirelyHelperKit

private let privB64 = "TUs1G5dtbPrNOrSqmV/Hddlk1MMbHw63dD4eIUlODZU="
private let pubB64 = "5eOWMvp44rKHfFuhZU//t2b2q6SblullXT2n4eeapKw="

private func configText(allowed: String = "0.0.0.0/0", dns: String? = "1.1.1.1",
                        tableOff: Bool = false, extra: String = "") -> String {
    var s = "[Interface]\nPrivateKey = \(privB64)\nAddress = 10.8.0.2/32\n"
    if let dns { s += "DNS = \(dns)\n" }
    if tableOff { s += "Table = off\n" }
    s += extra
    s += "[Peer]\nPublicKey = \(pubB64)\nEndpoint = vpn.example.com:51820\nAllowedIPs = \(allowed)\n"
    return s
}

private func configText(address: String, allowed: String) -> String {
    configText(allowed: allowed).replacingOccurrences(of: "Address = 10.8.0.2/32", with: "Address = \(address)")
}

private func dnsEntry(_ service: String, _ servers: [String] = []) -> DNSBackup {
    DNSBackup(service: service, servers: servers, searchDomains: [])
}

private final class Env {
    let runner = FakeRunner()
    let store = MemoryStore()
    var launchers: [FakeLauncher] = []
    var launcher: FakeLauncher { launchers[launchers.count - 1] }
    var statuses: [TunnelStatus] = []
    var resolver = FakeResolver(table: ["vpn.example.com": "203.0.113.5"])
    let dns: FakeDNSConfigurator
    let firewall = FakeFirewall()
    var manager: TunnelManager!

    init(wifiDNS: [String] = []) {
        dns = FakeDNSConfigurator([dnsEntry("Wi-Fi", wifiDNS), dnsEntry("USB LAN")])
        runner.script(NetPlan.netstatCommand(.v4),
                      stdout: "Destination Gateway Flags Netif Expire\ndefault 192.168.1.1 UGScg en0\n")
        runner.script(NetPlan.ifconfigShow("en0"), stdout: "en0: flags=8863<UP> mtu 1500\n")
        runner.script(NetPlan.routeGet(IPAddress("203.0.113.5")!), stdout: "   interface: en0\n")
        let r = runner
        manager = TunnelManager(
            runner: r,
            makeLauncher: { [unowned self] in
                let l = FakeLauncher(runner: r)
                self.launchers.append(l)
                return l
            },
            resolver: resolver, store: store, dns: dns, firewall: firewall, log: { _ in },
            now: { Date(timeIntervalSince1970: 1_000) })
        manager.onStatusChange = { [unowned self] in self.statuses.append($0) }
    }
}

private func cmd(_ path: String, _ args: String...) -> NetCommand { NetCommand(path, args) }
private let route = "/sbin/route"
private let bypassAdd = "/sbin/route -q -n add -inet 203.0.113.5 -gateway 192.168.1.1"
private let bypassDelete = "/sbin/route -q -n delete -inet 203.0.113.5"

@Test func upFullTunnelRunsCommandsInOrder() throws {
    let env = Env()
    let status = try env.manager.up(name: "home", configText: configText())
    #expect(status.state == .connected)
    #expect(status.interface == "utun7")
    #expect(status.tunnelName == "home")
    #expect(env.launcher.configureTexts.count == 1)
    #expect(env.launcher.configureTexts[0].contains("endpoint=203.0.113.5:51820\n"))
    let bypass = try #require(env.runner.index(of: bypassAdd))
    let half = try #require(env.runner.index(of: "/sbin/route -q -n add -inet 0.0.0.0/1 -interface utun7"))
    #expect(bypass < half)
    #expect(env.runner.ran("/sbin/ifconfig utun7 mtu 1420"))
    #expect(env.dns.servers(of: "Wi-Fi") == ["1.1.1.1"])
    #expect(env.dns.servers(of: "USB LAN") == ["1.1.1.1"])
    #expect(env.dns.applied.count == 1)   // every service in one commit
    let saved = try #require(env.store.state)
    #expect(saved.dnsBackups.count == 2)
    #expect(saved.dnsBackups.allSatisfy { $0.servers.isEmpty && $0.searchDomains.isEmpty })
    #expect(saved.wireguardPID == 4242)
    #expect(env.manager.status().state == .connected)
}

@Test func downRestoresExactly() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText())
    env.runner.clearRecorded()
    let s = env.manager.down()
    #expect(s == .disconnected)
    #expect(env.runner.ran(bypassDelete))
    #expect(env.dns.services == [dnsEntry("Wi-Fi"), dnsEntry("USB LAN")])
    #expect(env.dns.applied.count == 2)
    #expect(env.launcher.stopped)
    #expect(env.store.state == nil)
    env.runner.clearRecorded()
    #expect(env.manager.down() == .disconnected)
    #expect(env.runner.commands.isEmpty)
    #expect(env.manager.status() == .disconnected)
}

@Test func restoresPreviousCustomDNS() throws {
    let env = Env(wifiDNS: ["8.8.8.8", "9.9.9.9"])
    _ = try env.manager.up(name: "home", configText: configText())
    _ = env.manager.down()
    #expect(env.dns.servers(of: "Wi-Fi") == ["8.8.8.8", "9.9.9.9"])
}

@Test func failedUpRollsBackEverything() throws {
    let env = Env()
    env.runner.fail(cmd(route, "-q", "-n", "add", "-inet", "128.0.0.0/1", "-interface", "utun7"))
    #expect(throws: TunnelError.commandFailed("/sbin/route -q -n add -inet 128.0.0.0/1 -interface utun7")) {
        try env.manager.up(name: "home", configText: configText())
    }
    #expect(env.launcher.stopped)
    #expect(env.runner.ran(bypassDelete))
    #expect(env.store.state == nil)
    #expect(env.manager.status() == .disconnected)
}

@Test func stateSaveFailureRestoresDNS() throws {
    let env = Env(wifiDNS: ["8.8.8.8"])
    let store = env.store
    // Let the incremental saves succeed, then fail once DNS has been applied.
    env.dns.onApply = { settings in
        if settings.first?.servers == ["1.1.1.1"] { store.failSave = true }
    }
    #expect(throws: TunnelError.self) {
        try env.manager.up(name: "home", configText: configText())
    }
    #expect(env.launcher.stopped)
    // Applied DNS must have been put back afterwards.
    #expect(env.dns.applied.count == 2)
    #expect(env.dns.applied[0].allSatisfy { $0.servers == ["1.1.1.1"] })
    #expect(env.dns.servers(of: "Wi-Fi") == ["8.8.8.8"])
    #expect(env.runner.ran(bypassDelete))
    #expect(env.store.state == nil)
}

@Test func interfaceUpFailureRollsBack() throws {
    let env = Env()
    env.runner.fail(cmd("/sbin/ifconfig", "utun7", "up"))
    #expect(throws: TunnelError.commandFailed("/sbin/ifconfig utun7 up")) {
        try env.manager.up(name: "home", configText: configText())
    }
    #expect(env.launcher.stopped)
    #expect(env.store.state == nil)
}

@Test func configureFailureRollsBack() throws {
    let env = Env()
    env.runner.fail(cmd("/sbin/ifconfig", "utun7", "mtu", "1420"))
    #expect(throws: TunnelError.commandFailed("/sbin/ifconfig utun7 mtu 1420")) {
        try env.manager.up(name: "home", configText: configText())
    }
    #expect(env.launcher.stopped)
    #expect(env.store.state == nil)
}

@Test func resolveFailureStartsNothing() throws {
    let env = Env()
    env.resolver = FakeResolver(table: [:])
    let r = env.runner
    let manager = TunnelManager(runner: r, makeLauncher: { [unowned env] in
        let l = FakeLauncher(runner: r); env.launchers.append(l); return l
    }, resolver: env.resolver, store: env.store, dns: env.dns, firewall: env.firewall, log: { _ in })
    #expect(throws: TunnelError.resolve("vpn.example.com")) {
        try manager.up(name: "home", configText: configText())
    }
    #expect(env.launchers.isEmpty)
    #expect(r.commands.isEmpty)
}

@Test func configErrorIsReported() throws {
    let env = Env()
    #expect(throws: TunnelError.config(.noPeers)) {
        try env.manager.up(name: "x", configText: "[Interface]\nPrivateKey = \(privB64)\n")
    }
    #expect(env.runner.commands.isEmpty)
}

@Test func networkChangeRepointsEndpointRoute() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText())
    env.runner.script(NetPlan.netstatCommand(.v4),
                      stdout: "Destination Gateway Flags Netif Expire\ndefault 10.0.0.1 UGScg en1\n")
    env.runner.clearRecorded()
    env.manager.networkChanged()
    let del = try #require(env.runner.index(of: bypassDelete))
    let add = try #require(env.runner.index(of: "/sbin/route -q -n add -inet 203.0.113.5 -gateway 10.0.0.1"))
    #expect(del < add)
    let stored = try #require(env.store.state)
    #expect(stored.endpointRoutes.first?.command.description
            == "/sbin/route -q -n add -inet 203.0.113.5 -gateway 10.0.0.1")
}

@Test func networkChangeWithSameGatewayLeavesRoute() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText())
    env.runner.clearRecorded()
    env.manager.networkChanged()
    #expect(!env.runner.ran(bypassDelete))
    #expect(!env.runner.ran(bypassAdd))
}

@Test func networkChangeKeepsOriginalDNSBackup() throws {
    let env = Env(wifiDNS: ["8.8.8.8"])
    _ = try env.manager.up(name: "home", configText: configText())
    // Something else rewrote Wi-Fi's DNS while we were connected: re-apply ours, keep the original backup.
    env.dns.services[0] = dnsEntry("Wi-Fi", ["9.9.9.9"])
    env.manager.networkChanged()
    #expect(env.dns.servers(of: "Wi-Fi") == ["1.1.1.1"])
    let wifi = try #require(env.store.state?.dnsBackups.first { $0.service == "Wi-Fi" })
    #expect(wifi.servers == ["8.8.8.8"])
    _ = env.manager.down()
    #expect(env.dns.servers(of: "Wi-Fi") == ["8.8.8.8"])
}

@Test func networkChangeWithoutDNSDriftDoesNotCommit() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText())
    env.manager.networkChanged()
    #expect(env.dns.applied.count == 1)
}

@Test func networkChangeBacksUpNewServices() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText())
    env.dns.services.append(dnsEntry("Thunderbolt", ["4.4.4.4"]))
    env.manager.networkChanged()
    #expect(env.dns.servers(of: "Thunderbolt") == ["1.1.1.1"])
    #expect(env.store.state?.dnsBackups.first { $0.service == "Thunderbolt" }?.servers == ["4.4.4.4"])
}

@Test func dnsReadFailureAbortsConnect() {
    let env = Env()
    env.dns.failSnapshot = true
    #expect(throws: TunnelError.self) {
        try env.manager.up(name: "home", configText: configText())
    }
    #expect(env.launcher.stopped)
    #expect(env.dns.applied.isEmpty)
    #expect(env.store.state == nil)
}

@Test func networkChangeIsNoOpWhenInactive() {
    let env = Env()
    env.manager.networkChanged()
    #expect(env.runner.commands.isEmpty)
}

@Test func tableOffAddsNoRoutes() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText(tableOff: true))
    #expect(!env.runner.commands.contains { $0.path == route })
}

@Test func splitTunnelNoBypass() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText(allowed: "10.8.0.0/24"))
    let routes = env.runner.commands.filter { $0.path == route }.map(\.description)
    #expect(routes == ["/sbin/route -q -n add -inet 10.8.0.0/24 -interface utun7"])
    #expect(env.store.state?.endpointRoutes.isEmpty == true)
}

@Test func secondUpTearsDownFirst() throws {
    let env = Env()
    _ = try env.manager.up(name: "A", configText: configText())
    _ = try env.manager.up(name: "B", configText: configText())
    let starts = env.runner.events.enumerated().filter { $0.element == "launcher.start" }.map(\.offset)
    #expect(starts.count == 2)
    let firstStop = try #require(env.runner.events.firstIndex(of: "launcher.stop"))
    let firstDelete = try #require(env.runner.events.firstIndex(of: bypassDelete))
    #expect(firstStop < starts[1])
    #expect(firstDelete < starts[1])
    #expect(env.manager.status().tunnelName == "B")
}

@Test func ignoredKeysReported() throws {
    let env = Env()
    let s = try env.manager.up(name: "home", configText: configText(extra: "PostUp = echo hi\n"))
    #expect(s.ignoredKeys == ["PostUp"])
    #expect(env.manager.status().ignoredKeys == ["PostUp"])
    #expect(!env.runner.commands.contains { $0.description.contains("PostUp") })
}

@Test func unexpectedExitRestores() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText())
    env.runner.clearRecorded()
    env.statuses = []
    env.launcher.simulateExit()
    #expect(env.runner.ran(bypassDelete))
    #expect(env.dns.servers(of: "Wi-Fi") == [])
    #expect(env.store.state == nil)
    #expect(env.manager.status().state == .failed)
    #expect(env.manager.status().message == "wireguard-go beklenmedik şekilde kapandı")
    #expect(env.statuses.last?.state == .failed)
}

@Test func statusFillsCountersAndKeepsConnectedOnGetError() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText())
    env.launcher.getOutput = """
    public_key=\(Data(base64Encoded: pubB64)!.map { String(format: "%02x", $0) }.joined())
    endpoint=203.0.113.5:51820
    last_handshake_time_sec=100
    last_handshake_time_nsec=0
    rx_bytes=10
    tx_bytes=20
    errno=0

    """
    let s = env.manager.status()
    #expect(s.rxBytes == 10 && s.txBytes == 20)
    #expect(s.endpoint == "203.0.113.5:51820")
    #expect(s.lastHandshake == Date(timeIntervalSince1970: 100))
    #expect(s.connectedAt == Date(timeIntervalSince1970: 1_000))
    env.launcher.failGet = true
    let e = env.manager.status()
    #expect(e.state == .connected)
    #expect(e.message != nil)
}

@Test func statusChangeFiresOnConnectAndDisconnect() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText())
    _ = env.manager.down()
    #expect(env.statuses.map(\.state) == [.connected, .disconnected])
}

private func staleState() -> PersistedState {
    PersistedState(
        tunnelName: "home", interface: "utun7", wireguardPID: 4242,
        endpointRoutes: [EndpointRoute(ip: IPAddress("203.0.113.5")!, command: cmd(route, "x"))],
        dnsBackups: [DNSBackup(service: "Wi-Fi", servers: ["8.8.8.8"], searchDomains: [])],
        dnsServers: [IPAddress("1.1.1.1")!], dnsSearch: [],
        connectedAt: Date(timeIntervalSince1970: 0), ignoredKeys: [])
}

@Test func cleanupStaleKillsOnlyWireguard() {
    for (comm, shouldKill) in [("wireguard-go", true), ("Safari", false)] {
        let env = Env()
        env.store.state = staleState()
        env.runner.script(cmd("/bin/ps", "-p", "4242", "-o", "comm="), stdout: comm + "\n")
        env.manager.cleanupStale()
        #expect(env.runner.ran("/bin/kill -TERM 4242") == shouldKill)
        #expect(env.runner.ran(bypassDelete))
        #expect(env.dns.servers(of: "Wi-Fi") == ["8.8.8.8"])
        #expect(env.store.state == nil)
    }
}

@Test func stateIsPersistedAfterStart() {
    let env = Env()
    env.runner.fail(cmd("/sbin/ifconfig", "utun7", "mtu", "1420"))
    _ = try? env.manager.up(name: "home", configText: configText())
    #expect(env.store.saves.first?.interface == "utun7")
    #expect(env.store.saves.first?.wireguardPID == 4242)
    #expect(env.store.state == nil)
}

@Test func stateIsPersistedBeforeDNSApplied() throws {
    let env = Env(wifiDNS: ["8.8.8.8"])
    var checked = false
    let store = env.store
    env.dns.onApply = { settings in
        if settings.first?.servers == ["1.1.1.1"] {
            checked = true
            #expect(store.load()?.dnsBackups.first { $0.service == "Wi-Fi" }?.servers == ["8.8.8.8"])
        }
    }
    _ = try env.manager.up(name: "home", configText: configText())
    #expect(checked)
}

@Test func bypassRoutePersistedImmediately() throws {
    let env = Env()
    var seen = false
    let store = env.store
    env.runner.onRun = { c in
        if c.description == "/sbin/route -q -n add -inet 0.0.0.0/1 -interface utun7" {
            seen = true
            #expect(store.load()?.endpointRoutes.count == 1)
        }
    }
    _ = try env.manager.up(name: "home", configText: configText())
    #expect(seen)
}

@Test func networkChangeRestoresMissingBypassRoute() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText())
    env.runner.script(NetPlan.routeGet(IPAddress("203.0.113.5")!), stdout: "   interface: utun7\n")
    env.runner.clearRecorded()
    env.manager.networkChanged()
    let del = try #require(env.runner.index(of: bypassDelete))
    let add = try #require(env.runner.index(of: bypassAdd))
    #expect(del < add)
}

@Test func networkChangeRestoresRouteWhenGetFails() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText())
    env.runner.fail(NetPlan.routeGet(IPAddress("203.0.113.5")!))
    env.runner.clearRecorded()
    env.manager.networkChanged()
    #expect(env.runner.ran(bypassDelete) && env.runner.ran(bypassAdd))
}

@Test func networkChangeLeavesHealthyRouteAlone() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText())
    env.runner.clearRecorded()
    env.manager.networkChanged()
    #expect(!env.runner.ran(bypassDelete))
    #expect(!env.runner.ran(bypassAdd))
}

@Test func v4OnlyConfigBlocksIPv6() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText(allowed: "0.0.0.0/0, ::/0"))
    #expect(env.runner.ran("/sbin/route -q -n add -inet6 ::/1 ::1 -reject"))
    #expect(env.runner.ran("/sbin/route -q -n add -inet6 8000::/1 ::1 -reject"))
    #expect(!env.runner.ran("/sbin/route -q -n add -inet6 ::/1 -interface utun7"))
    #expect(env.runner.ran("/sbin/route -q -n add -inet 0.0.0.0/1 -interface utun7"))
    #expect(env.store.state?.rejectRoutes == [IPNetwork("::/1")!, IPNetwork("8000::/1")!])
    env.runner.clearRecorded()
    _ = env.manager.down()
    #expect(env.runner.ran("/sbin/route -q -n delete -inet6 ::/1"))
    #expect(env.runner.ran("/sbin/route -q -n delete -inet6 8000::/1"))
    #expect(env.store.state == nil)
}

@Test func dualStackConfigRoutesIPv6IntoTunnel() throws {
    let env = Env()
    _ = try env.manager.up(name: "home",
                           configText: configText(address: "10.8.0.2/32, fd00::2/128", allowed: "0.0.0.0/0, ::/0"))
    #expect(env.runner.ran("/sbin/route -q -n add -inet6 ::/1 -interface utun7"))
    #expect(env.runner.ran("/sbin/route -q -n add -inet6 8000::/1 -interface utun7"))
    #expect(!env.runner.commands.contains { $0.args.contains("-reject") })
    #expect(env.store.state?.rejectRoutes.isEmpty == true)
}

@Test func cleanupStaleRemovesRejectRoutes() {
    let env = Env()
    var st = staleState()
    st.rejectRoutes = [IPNetwork("::/1")!, IPNetwork("8000::/1")!]
    env.store.state = st
    env.manager.cleanupStale()
    #expect(env.runner.ran("/sbin/route -q -n delete -inet6 ::/1"))
    #expect(env.runner.ran("/sbin/route -q -n delete -inet6 8000::/1"))
    #expect(env.store.state == nil)
}

@Test func rejectRoutePersistedImmediately() throws {
    let env = Env()
    var seen = false
    let store = env.store
    env.runner.onRun = { c in
        if c.description == "/sbin/route -q -n add -inet6 8000::/1 ::1 -reject" {
            seen = true
            #expect(store.load()?.rejectRoutes == [IPNetwork("::/1")!])
        }
    }
    _ = try env.manager.up(name: "home", configText: configText(allowed: "0.0.0.0/0, ::/0"))
    #expect(seen)
}

@Test func persistedStateDecodesWithoutRejectRoutes() throws {
    var st = staleState()
    st.rejectRoutes = [IPNetwork("::/1")!]
    let data = try JSONEncoder().encode(st)
    var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["rejectRoutes"] != nil)
    obj.removeValue(forKey: "rejectRoutes")
    let old = try JSONSerialization.data(withJSONObject: obj)
    let decoded = try JSONDecoder().decode(PersistedState.self, from: old)
    #expect(decoded.rejectRoutes.isEmpty)
    #expect(decoded.tunnelName == st.tunnelName)
    #expect(try JSONDecoder().decode(PersistedState.self, from: data) == st)
}

// MARK: - Kill switch

@Test func noKillSwitchUnlessAsked() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText())
    #expect(env.firewall.loaded.isEmpty)
    #expect(env.manager.status().killSwitch == false)
    env.launcher.simulateExit()
    #expect(env.manager.status().state == .failed)
    #expect(!env.manager.status().isBlockedByKillSwitch)
}

@Test func killSwitchArmedBeforeTunnelStartsThenCoversIt() throws {
    let env = Env()
    let r = env.runner
    env.firewall.onEngage = { r.note("pf.engage") }
    let status = try env.manager.up(name: "home", configText: configText(), killSwitch: true)
    #expect(status.killSwitch == true)
    #expect(env.firewall.loaded.count == 2)
    #expect(!env.firewall.loaded[0].contains("utun7"))
    #expect(env.firewall.loaded[0].contains("to 203.0.113.5 port 51820"))
    #expect(env.firewall.loaded[1].contains("pass quick on utun7 all"))
    #expect(env.firewall.loaded[1].contains("192.168.0.0/16"))   // allowLAN defaults to on
    let firstEngage = try #require(r.events.firstIndex(of: "pf.engage"))
    let start = try #require(r.events.firstIndex(of: "launcher.start"))
    #expect(firstEngage < start)
    #expect(env.store.state?.killSwitch?.token == "t1")
}

@Test func killSwitchWithoutLAN() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText(), killSwitch: true, allowLAN: false)
    #expect(env.firewall.current?.contains("192.168.0.0/16") == false)
}

@Test func userDisconnectReleasesKillSwitch() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText(), killSwitch: true)
    _ = env.manager.down()
    #expect(!env.firewall.isEngaged())
    #expect(env.firewall.released == ["t1"])
    #expect(env.store.state == nil)
}

@Test func tunnelDropKeepsBlockingUntilDisconnect() throws {
    let env = Env(wifiDNS: ["8.8.8.8"])
    _ = try env.manager.up(name: "home", configText: configText(), killSwitch: true)
    env.launcher.simulateExit()
    // Routes and DNS are restored, but pf keeps blocking (without the dead tunnel interface).
    #expect(env.dns.servers(of: "Wi-Fi") == ["8.8.8.8"])
    #expect(env.runner.ran(bypassDelete))
    #expect(env.firewall.isEngaged())
    #expect(env.firewall.current?.contains("utun7") == false)
    #expect(env.firewall.released.isEmpty)
    let s = env.manager.status()
    #expect(s.isBlockedByKillSwitch)
    #expect(s.tunnelName == "home")
    #expect(env.store.state?.killSwitch?.token == "t1")
    // "Allow internet"
    #expect(env.manager.down() == .disconnected)
    #expect(!env.firewall.isEngaged())
    #expect(env.firewall.released == ["t1"])
    #expect(env.store.state == nil)
    #expect(env.manager.status() == .disconnected)
}

@Test func reconnectWhileBlockingNeverOpensTheGate() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText(), killSwitch: true)
    env.launcher.simulateExit()
    let status = try env.manager.up(name: "home", configText: configText(), killSwitch: true)
    #expect(status.state == .connected)
    #expect(env.firewall.released.isEmpty)       // never disengaged in between
    #expect(env.firewall.tokensTaken == 1)       // the same pf reference carried over
    // The hostname endpoint was resolved under a temporary DNS-allowing ruleset.
    #expect(env.firewall.loaded.contains { $0.contains("port 53") })
    #expect(env.firewall.current?.contains("port 53") == false)
    #expect(env.firewall.current?.contains("pass quick on utun7 all") == true)
}

@Test func switchingTunnelsKeepsKillSwitchEngaged() throws {
    let env = Env()
    _ = try env.manager.up(name: "A", configText: configText(), killSwitch: true)
    _ = try env.manager.up(name: "B", configText: configText(), killSwitch: true)
    #expect(env.firewall.released.isEmpty)
    #expect(env.firewall.tokensTaken == 1)
    #expect(env.manager.status().tunnelName == "B")
}

@Test func connectWithoutKillSwitchAfterDropReleasesIt() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText(), killSwitch: true)
    env.launcher.simulateExit()
    _ = try env.manager.up(name: "home", configText: configText())
    #expect(!env.firewall.isEngaged())
    #expect(env.firewall.released == ["t1"])
}

@Test func failedConnectFromCleanStateReleasesKillSwitch() {
    let env = Env()
    env.runner.fail(cmd(route, "-q", "-n", "add", "-inet", "128.0.0.0/1", "-interface", "utun7"))
    #expect(throws: TunnelError.self) {
        try env.manager.up(name: "home", configText: configText(), killSwitch: true)
    }
    #expect(!env.firewall.isEngaged())
    #expect(env.firewall.released == ["t1"])
    #expect(env.manager.status() == .disconnected)
}

@Test func failedReconnectWhileBlockingStaysBlocked() throws {
    let env = Env()
    _ = try env.manager.up(name: "home", configText: configText(), killSwitch: true)
    env.launcher.simulateExit()
    env.runner.fail(cmd(route, "-q", "-n", "add", "-inet", "128.0.0.0/1", "-interface", "utun7"))
    #expect(throws: TunnelError.self) {
        try env.manager.up(name: "home", configText: configText(), killSwitch: true)
    }
    #expect(env.firewall.isEngaged())
    #expect(env.firewall.released.isEmpty)
    #expect(env.manager.status().isBlockedByKillSwitch)
}

@Test func killSwitchEngageFailureAbortsConnect() {
    let env = Env()
    env.firewall.failEngage = true
    #expect(throws: TunnelError.self) {
        try env.manager.up(name: "home", configText: configText(), killSwitch: true)
    }
    #expect(env.launchers.isEmpty)    // never started a tunnel it couldn't protect
    #expect(env.manager.status() == .disconnected)
}

private func killSwitchState() -> PersistedState {
    var s = staleState()
    s.killSwitch = KillSwitchRecord(token: "t9", allowLAN: true,
                                    endpoints: [Endpoint(host: "203.0.113.5", port: 51820)])
    return s
}

@Test func helperRestartKeepsBlockingWhenRulesStillLoaded() throws {
    let env = Env()
    _ = try env.firewall.engage(rules: "loaded", token: "t9")
    env.store.state = killSwitchState()
    env.manager.cleanupStale()
    #expect(env.firewall.isEngaged())
    #expect(env.firewall.released.isEmpty)
    #expect(env.dns.servers(of: "Wi-Fi") == ["8.8.8.8"])   // everything else is restored
    #expect(env.manager.status().isBlockedByKillSwitch)
    #expect(env.store.state?.killSwitch?.token == "t9")
}

@Test func rebootWipedRulesSoStaleKillSwitchIsReleased() {
    let env = Env()
    env.store.state = killSwitchState()
    env.manager.cleanupStale()
    #expect(env.firewall.released == ["t9"])
    #expect(!env.firewall.isEngaged())
    #expect(env.manager.status() == .disconnected)
    #expect(env.store.state == nil)
}
