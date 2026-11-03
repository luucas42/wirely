import Testing
import Foundation
import WirelyCore
@testable import WirelyApp

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("wirely-split-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("split.json")
}

private func config(allowed: String) -> TunnelConfig {
    try! TunnelConfig.parse("""
    [Interface]
    PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    Address = 10.8.0.2/32

    [Peer]
    PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    Endpoint = vpn.example.com:51820
    AllowedIPs = \(allowed)
    """)
}

private func tunnel(_ name: String, allowed: String = "10.8.0.0/16") -> StoredTunnel {
    let c = config(allowed: allowed)
    return StoredTunnel(name: name, text: "[Interface]\n# \(name)", config: c, error: nil)
}

private func rule(_ s: String) -> SplitRule {
    guard case .success(let r) = SplitRule.parse(s) else { fatalError("bad sample rule \(s)") }
    return r
}

@MainActor
struct SplitStoreTests {
    @Test func defaultsToAllAndEmpty() {
        let store = SplitStore(url: tempURL())
        #expect(store.settings(for: "home") == SplitSettings())
    }

    @Test func roundTripAndPermissions() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SplitStore(url: url)
        store.setMode(.selected, for: "home")
        #expect(store.add("example.com", for: "home") == nil)
        #expect(store.add("10.2.2.4", for: "home") == nil)
        #expect(store.add("10.8.0.0/16", for: "office") == nil)

        let again = SplitStore(url: url)
        #expect(again.settings(for: "home").mode == .selected)
        #expect(again.settings(for: "home").rules.map(\.text) == ["10.2.2.4", "example.com"])
        #expect(again.settings(for: "office").rules.map(\.text) == ["10.8.0.0/16"])

        let fm = FileManager.default
        let file = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let dir = try fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(file == 0o600)
        #expect(dir == 0o700)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains("\"mode\" : \"selected\""))
        #expect(json.contains("\"example.com\""))
    }

    @Test func newRulesGoToTheTop() {
        let store = SplitStore(url: tempURL())
        _ = store.add("example.com", for: "home")
        _ = store.add("intranet.example.com", for: "home")
        _ = store.add("203.0.113.7", for: "home")
        #expect(store.settings(for: "home").rules.map(\.text) == ["203.0.113.7", "intranet.example.com", "example.com"])
    }

    @Test func renameMovesEntryAndDeleteRemovesIt() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SplitStore(url: url)
        _ = store.add("example.com", for: "home")
        store.renameProfile("home", to: "travel")
        #expect(store.settings(for: "home") == SplitSettings())
        #expect(store.settings(for: "travel").rules.map(\.text) == ["example.com"])
        #expect(SplitStore(url: url).settings(for: "travel").rules.count == 1)
        store.deleteProfile("travel")
        #expect(store.settings(for: "travel") == SplitSettings())
        #expect(SplitStore(url: url).all.isEmpty)
    }

    @Test func addErrors() {
        let store = SplitStore(url: tempURL())
        #expect(store.add("example.com", for: "home") == nil)
        #expect(store.add("EXAMPLE.com.", for: "home") == .duplicate("example.com"))
        #expect(store.add("10.2.2", for: "home") == .invalid(.notAnAddress))
        #expect(store.add("10.2.2.0/99", for: "home") == .invalid(.badPrefix))
        #expect(store.add("not a host!", for: "home") == .invalid(.notAHost))
        #expect(store.settings(for: "home").rules.count == 1)
    }

    @Test func capAtTwoHundred() {
        let store = SplitStore(url: tempURL())
        for i in 0..<200 { #expect(store.add("h\(i).example.com", for: "home") == nil) }
        #expect(store.add("one-more.example.com", for: "home") == .full)
        #expect(store.settings(for: "home").rules.count == 200)
    }

    @Test func removeDropsRule() {
        let store = SplitStore(url: tempURL())
        _ = store.add("example.com", for: "home")
        store.remove(rule("example.com"), for: "home")
        #expect(store.settings(for: "home").rules.isEmpty)
    }

    @Test func errorMessagesInBothLanguages() {
        let en = L10n(fixed: .en), tr = L10n(fixed: .tr)
        #expect(SplitAddError.invalid(.notAnAddress).message(en) == "That isn't an IP address.")
        #expect(SplitAddError.invalid(.notAnAddress).message(tr) == "Bu bir IP adresi değil.")
        #expect(SplitAddError.invalid(.badPrefix).message(en) == "The network prefix must be 0–32 (IPv4) or 0–128 (IPv6).")
        #expect(SplitAddError.invalid(.notAHost).message(tr) == "Bir site adı (example.com) ya da IP adresi yaz.")
        #expect(SplitAddError.duplicate("example.com").message(en) == "example.com is already in the list.")
        #expect(SplitAddError.duplicate("example.com").message(tr) == "example.com zaten listede.")
        #expect(SplitAddError.full.message(en) == "The list is full (200).")
        #expect(SplitAddError.full.message(tr) == "Liste dolu (200).")
    }

    @Test func tunnelStoreHooksKeepSplitInSync() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wirely-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let split = SplitStore(url: dir.appendingPathComponent("split.json"))
        let tunnels = TunnelStore(directory: dir.appendingPathComponent("Tunnels"))
        tunnels.onRenamed = { split.renameProfile($0, to: $1) }
        tunnels.onDeleted = { split.deleteProfile($0) }
        let text = """
        [Interface]
        PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
        Address = 10.8.0.2/32

        [Peer]
        PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
        Endpoint = vpn.example.com:51820
        AllowedIPs = 0.0.0.0/0
        """
        _ = try tunnels.add(name: "home", text: text)
        _ = split.add("example.com", for: "home")
        try tunnels.rename("home", to: "office")
        #expect(split.settings(for: "office").rules.count == 1)
        #expect(split.settings(for: "home").rules.isEmpty)
        tunnels.delete("office")
        #expect(split.all.isEmpty)
    }
}

@MainActor
final class FakeHelper {
    var requests: [HelperRequest] = []
    var reply: (HelperRequest) -> HelperResponse = { _ in
        HelperResponse(ok: true, error: nil, status: nil, helperVersion: HelperConstants.helperVersion)
    }
    func install(on c: ConnectionController) {
        c.sendOverride = { [unowned self] req in
            self.requests.append(req)
            return .success(self.reply(req))
        }
    }
}

@MainActor
struct SplitControllerTests {
    private func make() -> (ConnectionController, SplitStore, FakeHelper) {
        let store = SplitStore(url: tempURL())
        let c = ConnectionController(splitStore: store)
        let fake = FakeHelper()
        fake.install(on: c)
        return (c, store, fake)
    }

    private func connected(_ c: ConnectionController, _ name: String, split: [String: SplitRuleStatus]?) {
        c.status = TunnelStatus(state: .connected, tunnelName: name, split: split)
    }

    @Test func connectSendsSplitOnlyInSelectedMode() async {
        let (c, store, fake) = make()
        let t = tunnel("home")
        await c.connect(t)
        #expect(fake.requests.last?.command == .up)
        #expect(fake.requests.last?.split == nil)

        _ = store.add("example.com", for: "home")
        await c.connect(t)
        #expect(fake.requests.last?.split == nil) // mode still .all

        store.setMode(.selected, for: "home")
        await c.connect(t)
        #expect(fake.requests.last?.split == ["example.com"])

        store.remove(rule("example.com"), for: "home")
        await c.connect(t)
        #expect(fake.requests.last?.split == []) // selected + empty is still split mode
    }

    @Test func modeChangeWhileConnectedReconnects() async {
        let (c, store, fake) = make()
        let t = tunnel("home")
        connected(c, "home", split: nil)
        await c.setSplitMode(.selected, for: t)
        #expect(store.settings(for: "home").mode == .selected)
        #expect(fake.requests.map(\.command) == [.up])
        #expect(fake.requests.first?.split == [])
    }

    @Test func modeChangeWhileDisconnectedOnlySaves() async {
        let (c, store, fake) = make()
        await c.setSplitMode(.selected, for: tunnel("home"))
        #expect(store.settings(for: "home").mode == .selected)
        #expect(fake.requests.isEmpty)
        // Another profile being connected doesn't count either.
        connected(c, "office", split: nil)
        await c.setSplitMode(.all, for: tunnel("home"))
        #expect(fake.requests.isEmpty)
    }

    @Test func addWhileConnectedInSplitModeSendsFullList() async {
        let (c, store, fake) = make()
        let t = tunnel("home")
        _ = store.add("example.com", for: "home")
        connected(c, "home", split: ["example.com": SplitRuleStatus(routed: 2, rejected: 0)])
        fake.reply = { _ in
            HelperResponse(ok: true, error: nil,
                           status: TunnelStatus(state: .connected, tunnelName: "home",
                                                split: ["example.com": SplitRuleStatus(routed: 2, rejected: 0),
                                                        "10.2.2.4": SplitRuleStatus(routed: 1, rejected: 0)]),
                           helperVersion: HelperConstants.helperVersion)
        }
        let err = await c.addSplitRule("10.2.2.4", for: t)
        #expect(err == nil)
        #expect(fake.requests.count == 1)
        #expect(fake.requests[0].command == .split)
        #expect(fake.requests[0].split == ["10.2.2.4", "example.com"])
        #expect(c.splitCounts.count == 2)

        await c.removeSplitRule(rule("example.com"), for: t)
        #expect(fake.requests.count == 2)
        #expect(fake.requests[1].split == ["10.2.2.4"])
    }

    @Test func nothingSentWhenDisconnectedOrFullMode() async {
        let (c, store, fake) = make()
        let t = tunnel("home")
        #expect(await c.addSplitRule("example.com", for: t) == nil) // disconnected
        connected(c, "home", split: nil)                            // connected, full tunnel
        #expect(await c.addSplitRule("10.2.2.4", for: t) == nil)
        await c.removeSplitRule(rule("10.2.2.4"), for: t)
        connected(c, "office", split: [:])                          // other profile in split mode
        #expect(await c.addSplitRule("203.0.113.9", for: t) == nil)
        #expect(fake.requests.isEmpty)
        #expect(store.settings(for: "home").rules.map(\.text) == ["203.0.113.9", "example.com"])
    }

    @Test func addErrorIsReturnedAndNothingSent() async {
        let (c, _, fake) = make()
        let t = tunnel("home")
        connected(c, "home", split: [:])
        #expect(await c.addSplitRule("10.2.2", for: t) == .invalid(.notAnAddress))
        #expect(fake.requests.isEmpty)
    }

    @Test func helperErrorKeepsSavedRuleAndSetsLastError() async {
        let (c, store, fake) = make()
        let t = tunnel("home")
        connected(c, "home", split: [:])
        fake.reply = { _ in
            HelperResponse(ok: false, error: "x", status: nil, helperVersion: HelperConstants.helperVersion,
                           errorCode: "split.invalidRule", errorArg: "example.com")
        }
        _ = await c.addSplitRule("example.com", for: t)
        #expect(store.settings(for: "home").rules.map(\.text) == ["example.com"])
        #expect(c.lastError == L10n.shared.describe(helperErrorCode: "split.invalidRule", arg: nil, fallback: nil))
        #expect(c.lastError != "x")
    }

    @Test func splitErrorCodesLocalized() {
        let en = L10n(fixed: .en), tr = L10n(fixed: .tr)
        #expect(en.describe(helperErrorCode: "split.notActive", arg: nil, fallback: "raw") != "raw")
        #expect(tr.describe(helperErrorCode: "split.invalidRule", arg: nil, fallback: "raw") != "raw")
    }

    @Test func exposesCountsAndDNSState() {
        let (c, _, _) = make()
        #expect(c.splitCounts.isEmpty)
        #expect(c.splitDNSActive == nil)
        c.status = TunnelStatus(state: .connected, tunnelName: "home",
                                split: ["example.com": SplitRuleStatus(routed: 3, rejected: 1)], splitDNS: false)
        #expect(c.splitCounts["example.com"]?.routed == 3)
        #expect(c.splitDNSActive == false)
    }
}

struct SplitRowsTests {
    private let en = L10n(fixed: .en), tr = L10n(fixed: .tr)

    private func settings(_ texts: [String]) -> SplitSettings {
        SplitSettings(mode: .selected, rules: texts.map(rule))
    }

    private func rows(_ texts: [String], allowed: String = "10.8.0.0/16, 203.0.113.0/24",
                      counts: [String: SplitRuleStatus] = [:], connected: Bool = false,
                      dns: Bool? = nil, l10n: L10n? = nil) -> [SplitRow] {
        SplitRows.rows(settings: settings(texts), config: config(allowed: allowed), counts: counts,
                       connected: connected, splitDNS: dns, l10n: l10n ?? en)
    }

    @Test func domainSubtitles() {
        let counts = ["example.com": SplitRuleStatus(routed: 4, rejected: 0),
                      "intranet.example.com": SplitRuleStatus(routed: 0, rejected: 0)]
        let live = rows(["example.com", "intranet.example.com"], counts: counts, connected: true, dns: true)
        #expect(live[0].subtitle == "Including subdomains, 4 addresses in the tunnel")
        #expect(live[0].kind == .domain)
        #expect(live[1].subtitle == "Including subdomains, looking up…")
        #expect(live[0].warning == nil)
        #expect(rows(["example.com"], counts: counts).first?.subtitle == "Including subdomains")
        let trLive = rows(["example.com"], counts: counts, connected: true, dns: true, l10n: tr)
        #expect(trLive[0].subtitle == "Alt alan adlarıyla, 4 adres tünelde")
        #expect(rows(["example.com"], connected: true, dns: true, l10n: tr)[0].subtitle
                == "Alt alan adlarıyla, adresi aranıyor…")
        #expect(rows(["example.com"], l10n: tr)[0].subtitle == "Alt alan adlarıyla")
    }

    @Test func domainWarnings() {
        let counts = ["example.com": SplitRuleStatus(routed: 2, rejected: 3)]
        let rej = rows(["example.com"], counts: counts, connected: true, dns: true)
        #expect(rej[0].warning == "3 addresses aren't accepted by this server")
        #expect(rows(["example.com"], counts: counts, connected: true, dns: true, l10n: tr)[0].warning
                == "3 adres bu sunucuda kabul edilmiyor")
        // DNS proxy off wins over counts, and only matters while connected.
        let off = rows(["example.com"], counts: counts, connected: true, dns: false)
        #expect(off[0].warning == "Site rules are off: port 53 is in use by another app")
        #expect(off[0].subtitle == "Including subdomains")
        #expect(rows(["example.com"], connected: true, dns: false, l10n: tr)[0].warning
                == "Site kuralları kapalı: 53 portunu başka bir uygulama kullanıyor")
        #expect(rows(["example.com"], counts: counts, connected: false, dns: false)[0].warning == nil)
    }

    @Test func addressAndNetworkRows() {
        let r = rows(["10.2.2.4", "10.8.0.0/16", "198.51.100.0/24", "198.51.100.9"])
        let byValue = Dictionary(uniqueKeysWithValues: r.map { ($0.value, $0) })
        #expect(byValue["10.2.2.4"]?.kind == .address)
        #expect(byValue["10.2.2.4"]?.subtitle == "Single address")
        #expect(byValue["10.2.2.4"]?.warning == "This server doesn't accept traffic for this address") // 10.2.2.4 not in 10.8/16
        #expect(byValue["10.8.0.0/16"]?.kind == .network)
        #expect(byValue["10.8.0.0/16"]?.subtitle == "Network, 65,536 addresses")
        #expect(byValue["10.8.0.0/16"]?.warning == nil)
        #expect(r.count == 5) // 203.0.113.0/24 from the profile; 10.8.0.0/16 is not listed twice
        #expect(byValue["198.51.100.0/24"]?.subtitle == "Network, 256 addresses")
        #expect(byValue["198.51.100.0/24"]?.warning != nil)
        #expect(byValue["198.51.100.9"]?.warning != nil)
        #expect(rows(["203.0.113.7"])[0].warning == nil)
        let trRows = rows(["10.8.0.0/16", "10.2.2.4"], l10n: tr)
        #expect(trRows[0].subtitle == "Ağ, 65.536 adres")
        #expect(trRows[1].subtitle == "Tek adres")
        #expect(trRows[1].warning == "Bu sunucu bu adres için trafik kabul etmiyor")
    }

    @Test func hugeNetworksJustSayNetwork() {
        let r = rows(["10.0.0.0/7", "2001:db8::/32"], allowed: "0.0.0.0/0")
        #expect(r[0].subtitle == "Network")
        #expect(r[1].subtitle == "Network")
        #expect(rows(["10.0.0.0/7"], allowed: "0.0.0.0/0", l10n: tr)[0].subtitle == "Ağ")
        #expect(rows(["10.0.0.0/8"], allowed: "0.0.0.0/0")[0].subtitle == "Network, 16,777,216 addresses")
    }

    @Test func userRulesFirstThenProfileRows() {
        let r = rows(["example.com"])
        #expect(r.map(\.kind) == [.domain, .profile, .profile])
        #expect(r[1].value == "10.8.0.0/16")
        #expect(r[1].subtitle == "From the profile")
        #expect(r[1].removable == false)
        #expect(r[1].rule == nil)
        #expect(r[1].warning == nil)
        #expect(r[0].removable)
        #expect(r[0].rule == rule("example.com"))
        #expect(rows(["example.com"], l10n: tr)[1].subtitle == "Profilden")
    }

    @Test func defaultRouteProfileAddsNoRowsAndNoConfigNoWarnings() {
        #expect(rows(["example.com"], allowed: "0.0.0.0/0").count == 1)
        let noConfig = SplitRows.rows(settings: settings(["10.2.2.4"]), config: nil, counts: [:],
                                      connected: false, splitDNS: nil, l10n: en)
        #expect(noConfig.count == 1)
        #expect(noConfig[0].warning == nil)
    }

    @Test func summary() {
        #expect(SplitRows.summary(settings: SplitSettings(), l10n: en) == "All traffic through the tunnel")
        #expect(SplitRows.summary(settings: SplitSettings(), l10n: tr) == "Tüm trafik tünelden")
        let s = settings(["example.com", "10.2.2.4", "10.8.0.0/16"])
        #expect(SplitRows.summary(settings: s, l10n: en) == "Split, 3 targets")
        #expect(SplitRows.summary(settings: s, l10n: tr) == "Bölünmüş, 3 hedef")
        // Rules kept while the mode is "all" don't show as a split.
        #expect(SplitRows.summary(settings: SplitSettings(mode: .all, rules: s.rules), l10n: en)
                == "All traffic through the tunnel")
    }
}
