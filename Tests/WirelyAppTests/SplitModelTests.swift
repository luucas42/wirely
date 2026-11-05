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

private func entry(_ s: String) -> SplitEntry { .rule(rule(s)) }

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
        store.remove(entry("example.com"), from: .selected, for: "home")
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

        store.remove(entry("example.com"), from: .selected, for: "home")
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
        store.setMode(.selected, for: "home")
        connected(c, "home", split: ["example.com": SplitRuleStatus(routed: 2, rejected: 0)])
        fake.reply = { _ in
            HelperResponse(ok: true, error: nil,
                           status: TunnelStatus(state: .connected, tunnelName: "home",
                                                split: ["example.com": SplitRuleStatus(routed: 2, rejected: 0),
                                                        "10.2.2.4": SplitRuleStatus(routed: 1, rejected: 0)]),
                           helperVersion: HelperConstants.helperVersion)
        }
        let err = await c.addSplitEntry("10.2.2.4", for: t)
        #expect(err == .added)
        #expect(fake.requests.count == 1)
        #expect(fake.requests[0].command == .split)
        #expect(fake.requests[0].split == ["10.2.2.4", "example.com"])
        #expect(c.splitCounts.count == 2)

        await c.removeSplitEntry(entry("example.com"), for: t)
        #expect(fake.requests.count == 2)
        #expect(fake.requests[1].split == ["10.2.2.4"])
    }

    @Test func nothingSentWhenDisconnectedOrFullMode() async {
        let (c, store, fake) = make()
        let t = tunnel("home")
        store.setMode(.selected, for: "home")
        #expect(await c.addSplitEntry("example.com", for: t) == .added) // disconnected
        connected(c, "home", split: nil)                                // connected, but not in split mode
        #expect(await c.addSplitEntry("10.2.2.4", for: t) == .added)
        await c.removeSplitEntry(entry("10.2.2.4"), for: t)
        connected(c, "office", split: [:])                              // other profile in split mode
        #expect(await c.addSplitEntry("203.0.113.9", for: t) == .added)
        #expect(fake.requests.isEmpty)
        #expect(store.settings(for: "home").rules.map(\.text) == ["203.0.113.9", "example.com"])
    }

    @Test func addErrorIsReturnedAndNothingSent() async {
        let (c, _, fake) = make()
        let t = tunnel("home")
        connected(c, "home", split: [:])
        #expect(await c.addSplitEntry("10.2.2", for: t) == .failed(.invalid(.notAnAddress)))
        #expect(fake.requests.isEmpty)
    }

    @Test func helperErrorKeepsSavedRuleAndSetsLastError() async {
        let (c, store, fake) = make()
        let t = tunnel("home")
        store.setMode(.selected, for: "home")
        connected(c, "home", split: [:])
        fake.reply = { _ in
            HelperResponse(ok: false, error: "x", status: nil, helperVersion: HelperConstants.helperVersion,
                           errorCode: "split.invalidRule", errorArg: "example.com")
        }
        _ = await c.addSplitEntry("example.com", for: t)
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
        SplitSettings(mode: .selected, rules: texts.map(entry))
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
        #expect(r[0].entry == entry("example.com"))
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

// MARK: Exclude mode and service groups

@MainActor
struct SplitExcludeStoreTests {
    private func write(_ json: String) throws -> URL {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func fileFromVersion15LoadsUnchanged() throws {
        let url = try write(#"{"home":{"mode":"selected","rules":["example.com","10.2.2.4"]}}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = SplitStore(url: url).settings(for: "home")
        #expect(s.mode == .selected)
        #expect(s.lastSplit == .selected)
        #expect(s.rules == [entry("example.com"), entry("10.2.2.4")])
        #expect(s.excluded.isEmpty)
        #expect(s.expandedRules() == ["example.com", "10.2.2.4"])
    }

    @Test func serviceEntryRoundTripsAndIsNeverADomain() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SplitStore(url: url)
        store.setMode(.excluded, for: "home")
        #expect(store.toggleGroup("youtube", in: .excluded, for: "home") == .added)
        #expect(store.add("example.org", to: .excluded, for: "home") == .added)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains("\"service:youtube\""))
        let again = SplitStore(url: url).settings(for: "home")
        #expect(again.mode == .excluded)
        #expect(again.lastSplit == .excluded)
        #expect(again.excluded == [entry("example.org"), .service("youtube")])
        #expect(again.rules.isEmpty)
        // The text form is a group, not a site rule.
        #expect(SplitEntry(text: "service:youtube") == .service("youtube"))
        #expect(SplitRule.parse("service:youtube") == .failure(.notAHost))
        #expect(!again.expandedRules().contains { $0.hasPrefix("service") })
    }

    @Test func unknownServiceIsDropped() throws {
        let url = try write(#"{"home":{"mode":"excluded","excluded":["service:nope","service:spotify","example.org"]}}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = SplitStore(url: url).settings(for: "home")
        #expect(s.excluded == [.service("spotify"), entry("example.org")])
        #expect(SplitEntry(text: "service:nope") == nil)
    }

    @Test func dottedAliasAddsTheGroup() {
        let store = SplitStore(url: tempURL())
        #expect(store.add("youtube.com", to: .excluded, for: "home") == .addedGroup(name: "YouTube", typed: "youtube.com"))
        #expect(store.settings(for: "home").excluded == [.service("youtube")])
        #expect(store.add("https://www.youtube.com/watch?v=1", to: .excluded, for: "home") == .failed(.duplicate("YouTube")))
        // A plain name is not an alias: it stays a rule, a dotted unrelated site too.
        #expect(store.add("youtube", to: .excluded, for: "home") == .added)
        #expect(store.add("example.com", to: .excluded, for: "home") == .added)
        // Both directions have their own list.
        #expect(store.settings(for: "home").rules.isEmpty)
        #expect(store.add("x.com", to: .selected, for: "home") == .addedGroup(name: "X", typed: "x.com"))
        #expect(store.settings(for: "home").rules == [.service("x")])
        let tr = L10n(fixed: .tr)
        #expect(SplitAddOutcome.addedGroup(name: "YouTube", typed: "youtube.com").note(tr)
                == "youtube.com yerine YouTube grubu eklendi; sitenin ve uygulamanın diğer adresleri de kapsanıyor.")
        #expect(SplitAddOutcome.addedGroup(name: "YouTube", typed: "youtube.com").note(L10n(fixed: .en))
                == "Added the YouTube group instead of youtube.com, so the other addresses its site and app use are covered too.")
        #expect(SplitAddOutcome.added.note(tr) == nil)
    }

    @Test func suggestions() {
        #expect(ServiceGroups.suggestion(for: "you")?.id == "youtube")
        #expect(ServiceGroups.suggestion(for: "YouTube")?.id == "youtube")
        #expect(ServiceGroups.suggestion(for: "x.com")?.id == "x")
        #expect(ServiceGroups.suggestion(for: "https://www.twitter.com/home")?.id == "x")
        #expect(ServiceGroups.suggestion(for: "net")?.id == "netflix")
        #expect(ServiceGroups.suggestion(for: "yo") == nil)
        #expect(ServiceGroups.suggestion(for: "x") == nil)
        #expect(ServiceGroups.suggestion(for: "10.2.2.4") == nil)
        #expect(ServiceGroups.suggestion(for: "example.com") == nil)
        #expect(ServiceGroups.exactAlias("youtube") == nil)
        #expect(ServiceGroups.exactAlias("m.youtube.com")?.id == "youtube")
        #expect(ServiceGroups.exactAlias("example.com") == nil)
        // Not offered again once it is in the list.
        var s = SplitSettings(mode: .excluded, lastSplit: .excluded, excluded: [.service("youtube")])
        #expect(s.suggestion(for: "you") == nil)
        s.excluded = []
        #expect(s.suggestion(for: "you")?.name == "YouTube")
    }

    @Test func expansionDeDuplicates() {
        let yt = ServiceGroups.group(id: "youtube")!
        let s = SplitSettings(mode: .excluded, lastSplit: .excluded,
                              excluded: [entry("ytimg.com"), entry("example.org"), .service("youtube"),
                                         .service("x"), entry("x.com")])
        let expanded = s.expandedRules()
        #expect(expanded.first == "ytimg.com")
        #expect(expanded.count == Set(expanded).count)
        #expect(expanded.count == 2 + (yt.domains.count - 1) + 4)
        #expect(expanded[1] == "example.org")
        #expect(expanded.contains("googlevideo.com"))
        #expect(expanded.suffix(3) == ["twitter.com", "twimg.com", "t.co"])
        #expect(ServiceGroups.all.map(\.domains.count) == [9, 7, 4, 7, 5])
    }

    @Test func setModeRemembersTheDirection() {
        let store = SplitStore(url: tempURL())
        store.setMode(.excluded, for: "home")
        store.setMode(.all, for: "home")
        let s = store.settings(for: "home")
        #expect(s.mode == .all)
        #expect(s.lastSplit == .excluded)
        #expect(s.activeMode == .excluded)
        #expect(store.add("example.org", for: "home") == nil) // goes to the remembered direction
        #expect(store.settings(for: "home").excluded == [entry("example.org")])
    }

    @Test func capAppliesPerList() {
        let store = SplitStore(url: tempURL())
        for i in 0..<200 { #expect(store.add("h\(i).example.com", to: .selected, for: "home") == .added) }
        #expect(store.add("one-more.example.com", to: .selected, for: "home") == .failed(.full))
        #expect(store.toggleGroup("youtube", in: .selected, for: "home") == .failed(.full))
        #expect(store.add("one-more.example.com", to: .excluded, for: "home") == .added)
    }
}

@MainActor
struct SplitExcludeControllerTests {
    private func make() -> (ConnectionController, SplitStore, FakeHelper) {
        let store = SplitStore(url: tempURL())
        let c = ConnectionController(splitStore: store)
        let fake = FakeHelper()
        fake.install(on: c)
        return (c, store, fake)
    }

    @Test func connectCarriesExpandedRulesAndDirection() async {
        let (c, store, fake) = make()
        let t = tunnel("home")
        store.setMode(.excluded, for: "home")
        _ = store.add("example.org", to: .excluded, for: "home")
        store.toggleGroup("twitch", in: .excluded, for: "home")
        _ = store.add("example.com", to: .selected, for: "home")
        await c.connect(t)
        #expect(fake.requests.last?.command == .up)
        #expect(fake.requests.last?.splitExclude == true)
        #expect(fake.requests.last?.split == ["twitch.tv", "ttvnw.net", "jtvnw.net", "twitchcdn.net", "twitchsvc.net",
                                              "example.org"])
        store.setMode(.selected, for: "home")
        await c.connect(t)
        #expect(fake.requests.last?.split == ["example.com"])
        #expect(fake.requests.last?.splitExclude != true)
        store.setMode(.all, for: "home")
        await c.connect(t)
        #expect(fake.requests.last?.split == nil)
        #expect(fake.requests.last?.splitExclude != true)
    }

    @Test func switchingDirectionWhileConnectedReconnects() async {
        let (c, store, fake) = make()
        let t = tunnel("home")
        store.setMode(.selected, for: "home")
        c.status = TunnelStatus(state: .connected, tunnelName: "home", split: [:])
        await c.setSplitMode(.excluded, for: t)
        #expect(store.settings(for: "home").mode == .excluded)
        #expect(fake.requests.map(\.command) == [.up])
        #expect(fake.requests.first?.splitExclude == true)
        await c.setSplitMode(.excluded, for: t) // no change
        #expect(fake.requests.count == 1)
    }

    @Test func liveChangeInExcludeModeSendsExpandedRules() async {
        let (c, store, fake) = make()
        let t = tunnel("home")
        store.setMode(.excluded, for: "home")
        _ = store.add("example.org", to: .excluded, for: "home")
        c.status = TunnelStatus(state: .connected, tunnelName: "home", split: [:], splitExclude: true)
        let toggled = await c.toggleGroup("twitch", for: t)
        #expect(toggled == .added)
        #expect(fake.requests.count == 1)
        #expect(fake.requests[0].command == .split)
        #expect(fake.requests[0].splitExclude == nil) // the direction never changes live
        #expect(fake.requests[0].split == ["twitch.tv", "ttvnw.net", "jtvnw.net", "twitchcdn.net", "twitchsvc.net",
                                           "example.org"])
        #expect(await c.addSplitEntry("example.com", for: t) == .added)
        #expect(fake.requests[1].split?.first == "example.com")
        await c.removeSplitEntry(.service("twitch"), for: t)
        #expect(fake.requests[2].split == ["example.com", "example.org"])
        #expect(await c.toggleGroup("twitch", for: t) == .added)
        #expect(await c.toggleGroup("twitch", for: t) == .removed)
        #expect(fake.requests.count == 5)
        #expect(await c.addSplitEntry("youtube.com", for: t) == .addedGroup(name: "YouTube", typed: "youtube.com"))
        #expect(fake.requests.last?.split?.contains("googlevideo.com") == true)
    }

    @Test func nothingPushedWhenTheRunningDirectionDiffers() async {
        let (c, store, fake) = make()
        store.setMode(.excluded, for: "home")
        c.status = TunnelStatus(state: .connected, tunnelName: "home", split: [:]) // running "only selected"
        #expect(await c.addSplitEntry("example.org", for: tunnel("home")) == .added)
        #expect(fake.requests.isEmpty)
    }

    @Test func addingInAllModeSwitchesToLastSplit() async {
        let (c, store, fake) = make()
        let t = tunnel("home")
        store.setMode(.excluded, for: "home")
        store.setMode(.all, for: "home")
        #expect(await c.addSplitEntry("example.org", for: t) == .added)
        #expect(store.settings(for: "home").mode == .excluded)
        #expect(store.settings(for: "home").excluded == [entry("example.org")])
        #expect(fake.requests.isEmpty) // disconnected: only saved

        store.setMode(.all, for: "home")
        c.status = TunnelStatus(state: .connected, tunnelName: "home", split: nil)
        #expect(await c.toggleGroup("spotify", for: t) == .added)
        #expect(store.settings(for: "home").mode == .excluded)
        #expect(fake.requests.map(\.command) == [.up]) // connected: reconnects into the split
        #expect(fake.requests[0].splitExclude == true)
        #expect(fake.requests[0].split?.first == "spotify.com")

        // A refused entry doesn't change the mode.
        store.setMode(.all, for: "home")
        #expect(await c.addSplitEntry("not a host!", for: t) == .failed(.invalid(.notAHost)))
        #expect(store.settings(for: "home").mode == .all)
    }

    @Test func excludeNeedsTheNewService() async {
        let (c, store, fake) = make()
        let t = tunnel("home")
        store.setMode(.excluded, for: "home")
        c.helperState = .outdated(8)
        #expect(!c.excludeSupported)
        await c.connect(t)
        // The old service gets the full tunnel, never the list alone, and the app asks for the update.
        #expect(fake.requests.count == 1)
        #expect(fake.requests[0].split == nil && fake.requests[0].splitExclude == nil)
        #expect(c.lastError == L10n.shared(.serviceUpdateNeeded))
        // Only exclude is held back.
        store.setMode(.selected, for: "home")
        await c.connect(t)
        #expect(fake.requests.count == 2)
        #expect(fake.requests[1].split != nil)
        c.helperState = .outdated(9)
        #expect(c.excludeSupported)
        c.helperState = .ready
        #expect(c.excludeSupported)
        #expect(ConnectionController.excludeMinHelperVersion == HelperConstants.helperVersion)
    }
}

struct SplitExcludeRowsTests {
    private let en = L10n(fixed: .en), tr = L10n(fixed: .tr)

    private func settings(_ list: [SplitEntry], mode: SplitMode = .excluded) -> SplitSettings {
        SplitSettings(mode: mode, lastSplit: mode == .all ? .excluded : mode, rules: mode == .selected ? list : [],
                      excluded: mode == .selected ? [] : list)
    }

    private func rows(_ s: SplitSettings, counts: [String: SplitRuleStatus] = [:], connected: Bool = false,
                      dns: Bool? = nil, l10n: L10n? = nil) -> [SplitRow] {
        SplitRows.rows(settings: s, config: config(allowed: "10.8.0.0/16"), counts: counts,
                       connected: connected, splitDNS: dns, l10n: l10n ?? en)
    }

    @Test func groupRowSumsRoutedOverItsDomains() {
        let counts = ["youtube.com": SplitRuleStatus(routed: 4, rejected: 0),
                      "googlevideo.com": SplitRuleStatus(routed: 6, rejected: 0),
                      "example.org": SplitRuleStatus(routed: 50, rejected: 0)]
        let s = settings([.service("youtube"), entry("example.org")])
        let r = rows(s, counts: counts, connected: true, dns: true)
        #expect(r.count == 2) // no profile rows in exclude mode
        #expect(r[0].kind == .group)
        #expect(r[0].value == "YouTube")
        #expect(r[0].entry == .service("youtube"))
        #expect(r[0].rule == nil)
        #expect(r[0].removable)
        #expect(r[0].domains == ServiceGroups.group(id: "youtube")!.domains)
        #expect(r[0].subtitle == "9 domains, 10 addresses outside the tunnel")
        #expect(r[1].subtitle == "Including subdomains, 50 addresses outside the tunnel")
        let trRows = rows(s, counts: counts, connected: true, dns: true, l10n: tr)
        #expect(trRows[0].subtitle == "9 alan adı, 10 adres normal hattan")
        #expect(trRows[1].subtitle == "Alt alan adlarıyla, 50 adres normal hattan")
        // Disconnected, or nothing learned yet: just the domain count.
        #expect(rows(s)[0].subtitle == "9 domains")
        #expect(rows(s, connected: true, dns: true)[0].subtitle == "9 domains")
        #expect(rows(s, l10n: tr)[0].subtitle == "9 alan adı")
        #expect(rows(s, counts: counts, connected: true, dns: false)[0].warning
                == "Site rules are off: port 53 is in use by another app")
        // The same group in the "only selected" list counts "in the tunnel".
        let inc = rows(settings([.service("youtube")], mode: .selected), counts: counts, connected: true, dns: true)
        #expect(inc[0].subtitle == "9 domains, 10 addresses in the tunnel")
        #expect(rows(settings([.service("youtube")], mode: .selected), counts: counts, connected: true, dns: true,
                     l10n: tr)[0].subtitle == "9 alan adı, 10 adres tünelde")
    }

    @Test func excludeAddressRowsAndIPv6Warning() {
        let s = settings([entry("2001:db8::1"), entry("198.51.100.0/24"), entry("203.0.113.7"), entry("2001:db8::/32")])
        let r = rows(s)
        let byValue = Dictionary(uniqueKeysWithValues: r.map { ($0.value, $0) })
        #expect(byValue["203.0.113.7"]?.subtitle == "Single address, outside the tunnel")
        #expect(byValue["203.0.113.7"]?.warning == nil)
        #expect(byValue["198.51.100.0/24"]?.warning == nil) // AllowedIPs coverage doesn't apply to exclusions
        #expect(byValue["2001:db8::1"]?.warning == "IPv6 isn't supported for exclusions")
        #expect(byValue["2001:db8::/32"]?.warning == "IPv6 isn't supported for exclusions")
        #expect(rows(s, l10n: tr).first { $0.value == "2001:db8::1" }?.warning == "IPv6 dışlamaları desteklenmiyor")
        #expect(rows(s, l10n: tr).first { $0.value == "203.0.113.7" }?.subtitle == "Tek adres, normal hattan")
    }

    @Test func allModeShowsTheRememberedList() {
        let s = SplitSettings(mode: .all, lastSplit: .excluded, rules: [entry("example.com")],
                              excluded: [.service("x")])
        #expect(rows(s).map(\.value) == ["X"])
    }

    @Test func summaryAndStatusLine() {
        let two = settings([.service("youtube"), .service("spotify")])
        let three = settings([.service("youtube"), .service("spotify"), entry("example.org")])
        #expect(SplitRows.summary(settings: three, l10n: en) == "Tunnel, 3 excluded")
        #expect(SplitRows.summary(settings: three, l10n: tr) == "Tümü tünelden, 3 hariç")
        #expect(SplitRows.statusLine(settings: three, l10n: tr) == "YouTube, Spotify ve 1 hedef normal hattan")
        #expect(SplitRows.statusLine(settings: three, l10n: en) == "YouTube, Spotify and 1 more skip the tunnel")
        #expect(SplitRows.statusLine(settings: two, l10n: tr) == "YouTube ve Spotify normal hattan")
        #expect(SplitRows.statusLine(settings: two, l10n: en) == "YouTube and Spotify skip the tunnel")
        #expect(SplitRows.statusLine(settings: settings([entry("example.org")]), l10n: en) == "example.org skips the tunnel")
        #expect(SplitRows.statusLine(settings: settings([]), l10n: en) == nil)
        #expect(SplitRows.statusLine(settings: SplitSettings(), l10n: en) == nil)
        #expect(SplitRows.statusLine(settings: settings([entry("example.org")], mode: .selected), l10n: tr)
                == "Gerisi normal bağlantından")
        // Lists kept while the mode is "all" don't show.
        #expect(SplitRows.summary(settings: settings([entry("example.org")], mode: .all), l10n: en)
                == "All traffic through the tunnel")
    }

    @Test func newStringsExistInBothLanguages() {
        #expect(en(.splitDirLabel) == "Listed items")
        #expect(tr(.splitDirLabel) == "Listedekiler tünelden")
        #expect(en(.splitDirInclude) == "use the tunnel" && en(.splitDirExclude) == "skip the tunnel")
        #expect(tr(.splitDirInclude) == "gitsin" && tr(.splitDirExclude) == "gitmesin")
        #expect(tr(.splitTopSplit) == "Bölünmüş" && en(.splitTopSplit) == "Split")
        #expect(tr(.splitAddGroup) == "Grubu ekle" && tr(.splitPresets) == "Hazır:")
        #expect(tr.format(.splitSuggestionTail, 9) == "grubu: sitenin ve uygulamanın kullandığı 9 alan adı")
        #expect(tr(.splitBlockedExcluded) == "Tünel düştü, kill switch listedekiler dışında her şeyi engelliyor.")
        #expect(SplitAddError.invalid(.notAHost).message(tr, list: .excluded)
                == "Bir site adı (example.com), IP ya da servis adı yaz.")
        #expect(SplitAddError.duplicate("YouTube").message(tr) == "YouTube zaten listede.")
    }
}
