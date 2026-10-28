import Testing
import Foundation
@testable import WirelyApp

private final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var responses: [String: Data] = [:]   // host -> body; missing -> throws
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }

    private func record(_ url: URL) { lock.withLock { _urls.append(url) } }

    func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
        record(url)
        guard let host = url.host, let d = responses[host] else { throw URLError(.cannotConnectToHost) }
        return d
    }
}

private let ipwhoJSON = Data(#"{"ip":"203.0.113.10","success":true,"country_code":"DE","city":"Frankfurt am Main","latitude":50.115524,"longitude":8.6841725}"#.utf8)
private let ipinfoJSON = Data(#"{"ip":"203.0.113.10","city":"Frankfurt am Main","country":"DE","loc":"50.1155,8.6842"}"#.utf8)

private func makeDefaults() -> (UserDefaults, String) {
    let name = "wirely.tests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

struct ServicesTests {
    @Test func parsesIpwho() {
        let l = ExitLocator.parseIpwho(ipwhoJSON, now: Date(timeIntervalSince1970: 5))
        #expect(l?.city == "Frankfurt am Main")
        #expect(l?.countryCode == "DE")
        #expect(abs((l?.point.lat ?? 0) - 50.115524) < 1e-6)
        #expect(abs((l?.point.lon ?? 0) - 8.6841725) < 1e-6)
        #expect(ExitLocator.parseIpwho(Data(#"{"success":false,"message":"x"}"#.utf8)) == nil)
    }

    @Test func parsesIpinfo() {
        let l = ExitLocator.parseIpinfo(ipinfoJSON)
        #expect(l?.city == "Frankfurt am Main")
        #expect(l?.countryCode == "DE")
        #expect(abs((l?.point.lat ?? 0) - 50.1155) < 1e-6)
        #expect(abs((l?.point.lon ?? 0) - 8.6842) < 1e-6)
        #expect(ExitLocator.parseIpinfo(Data(#"{"city":"X","country":"DE","loc":"bad"}"#.utf8)) == nil)
    }

    @Test func fallsBackToIpinfo() async {
        let http = FakeHTTP()
        http.responses["ipinfo.io"] = ipinfoJSON
        let (d, name) = makeDefaults(); defer { d.removePersistentDomain(forName: name) }
        let loc = await ExitLocator(http: http, defaults: d).location(for: "203.0.113.10")
        #expect(loc?.countryCode == "DE")
        #expect(http.urls.map { $0.host } == ["ipwho.is", "ipinfo.io"])
    }

    @Test func lookupFailureYieldsNil() async {
        let http = FakeHTTP()
        let (d, name) = makeDefaults(); defer { d.removePersistentDomain(forName: name) }
        #expect(await ExitLocator(http: http, defaults: d).location(for: "203.0.113.10") == nil)
        http.responses["ipwho.is"] = Data("garbage".utf8)
        http.responses["ipinfo.io"] = Data("{}".utf8)
        #expect(await ExitLocator(http: http, defaults: d).location(for: "203.0.113.10") == nil)
    }

    @Test func cacheHitSkipsNetwork() async {
        let http = FakeHTTP()
        http.responses["ipwho.is"] = ipwhoJSON
        let (d, name) = makeDefaults(); defer { d.removePersistentDomain(forName: name) }
        let loc = ExitLocator(http: http, defaults: d)
        let a = await loc.location(for: "203.0.113.10")
        let b = await loc.location(for: "203.0.113.10")
        #expect(a != nil && a == b)
        #expect(http.urls.count == 1)
        // A fresh locator over the same defaults also hits the persisted cache.
        _ = await ExitLocator(http: http, defaults: d).location(for: "203.0.113.10")
        #expect(http.urls.count == 1)
    }

    @Test func cacheExpiresAfter30Days() async {
        let http = FakeHTTP()
        http.responses["ipwho.is"] = ipwhoJSON
        let (d, name) = makeDefaults(); defer { d.removePersistentDomain(forName: name) }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let box = ClockBox(clock)
        let loc = ExitLocator(http: http, defaults: d, now: { box.value })
        _ = await loc.location(for: "203.0.113.10")
        clock.addTimeInterval(29 * 86400); box.value = clock
        _ = await loc.location(for: "203.0.113.10")
        #expect(http.urls.count == 1)
        clock.addTimeInterval(2 * 86400); box.value = clock
        _ = await loc.location(for: "203.0.113.10")
        #expect(http.urls.count == 2)
    }

    @Test func privateAddressesNotLookedUp() async {
        let http = FakeHTTP()
        http.responses["ipwho.is"] = ipwhoJSON
        let (d, name) = makeDefaults(); defer { d.removePersistentDomain(forName: name) }
        let loc = ExitLocator(http: http, defaults: d)
        for ip in ["10.0.0.1", "172.16.5.5", "172.31.255.255", "192.168.1.1", "100.64.0.1", "127.0.0.1", "fc00::1", "fd12::1", "fe80::1", "::1"] {
            #expect(await loc.location(for: ip) == nil, "\(ip)")
        }
        #expect(http.urls.isEmpty)
        #expect(ExitLocator.isPrivate("172.32.0.1") == false)
        #expect(ExitLocator.isPrivate("8.8.8.8") == false)
    }

    @Test func latencyMedianOfAttempts() {
        #expect(LatencyProbe.median([]) == nil)
        #expect(LatencyProbe.median([5]) == 5)
        #expect(LatencyProbe.median([30, 10, 20]) == 20)
        #expect(LatencyProbe.median([10, 20, 30, 40]) == 25)
    }

    @Test func hostResolverLiteralIPReturnsItself() async {
        #expect(await HostResolver.resolve("203.0.113.9") == "203.0.113.9")
        #expect(await HostResolver.resolve("2001:db8::1") == "2001:db8::1")
    }
}

private final class ClockBox: @unchecked Sendable {
    var value: Date
    init(_ v: Date) { value = v }
}
