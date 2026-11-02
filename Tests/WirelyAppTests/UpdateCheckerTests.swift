import Testing
import Foundation
@testable import WirelyApp

private final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _body: Data?
    var count: Int { lock.withLock { _count } }
    var body: Data? {
        get { lock.withLock { _body } }
        set { lock.withLock { _body = newValue } }
    }

    func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
        lock.withLock { _count += 1 }
        guard let body else { throw URLError(.cannotConnectToHost) }
        return body
    }
}

private func releaseJSON(_ tag: String) -> Data {
    Data("""
    {"tag_name":"\(tag)","name":"Wirely \(tag)","body":"Notes","html_url":"https://example.com/releases/\(tag)",
     "draft":false,"published_at":"2026-11-01T10:00:00Z",
     "assets":[{"name":"Wirely.dmg","browser_download_url":"https://example.com/Wirely.dmg"}]}
    """.utf8)
}

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

private func v(_ s: String) -> AppVersion { AppVersion(s)! }

@MainActor
private func make(_ http: FakeHTTP, current: String = "1.1.0", defaults: UserDefaults, clock: Clock = Clock()) -> UpdateChecker {
    UpdateChecker(http: http, current: v(current), defaults: defaults, now: { clock.now })
}

private func makeDefaults() -> (UserDefaults, String) {
    let name = "wirely.tests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

@MainActor
struct UpdateCheckerTests {
    @Test func newerReleaseIsAvailable() async {
        let (d, n) = makeDefaults(); defer { d.removePersistentDomain(forName: n) }
        let http = FakeHTTP(); http.body = releaseJSON("v1.2.0")
        let u = make(http, defaults: d)
        await u.checkIfDue()
        guard case .available(let r) = u.state else { Issue.record("state \(u.state)"); return }
        #expect(r.version == v("1.2.0"))
        #expect(u.bannerRelease == r)
    }

    @Test func sameVersionIsUpToDate() async {
        let (d, n) = makeDefaults(); defer { d.removePersistentDomain(forName: n) }
        let http = FakeHTTP(); http.body = releaseJSON("v1.1.0")
        let u = make(http, defaults: d)
        await u.checkIfDue()
        #expect(u.state == .upToDate)
        #expect(u.bannerRelease == nil)
    }

    @Test func notDueWithin24Hours() async {
        let (d, n) = makeDefaults(); defer { d.removePersistentDomain(forName: n) }
        let http = FakeHTTP(); http.body = releaseJSON("v1.1.0")
        let clock = Clock()
        let u = make(http, defaults: d, clock: clock)
        await u.checkIfDue()
        clock.now.addTimeInterval(UpdateChecker.interval - 60)
        await u.checkIfDue()
        #expect(http.count == 1)
    }

    @Test func dueAfter24Hours() async {
        let (d, n) = makeDefaults(); defer { d.removePersistentDomain(forName: n) }
        let http = FakeHTTP(); http.body = releaseJSON("v1.1.0")
        let clock = Clock()
        let u = make(http, defaults: d, clock: clock)
        await u.checkIfDue()
        clock.now.addTimeInterval(UpdateChecker.interval)
        await u.checkIfDue()
        #expect(http.count == 2)
    }

    @Test func autoCheckOffMakesNoRequest() async {
        let (d, n) = makeDefaults(); defer { d.removePersistentDomain(forName: n) }
        let http = FakeHTTP(); http.body = releaseJSON("v1.2.0")
        let u = make(http, defaults: d)
        u.autoCheck = false
        await u.checkIfDue()
        #expect(http.count == 0)
        #expect(u.state == .idle)
    }

    @Test func silentFailureOnAutoCheck() async {
        let (d, n) = makeDefaults(); defer { d.removePersistentDomain(forName: n) }
        let http = FakeHTTP()
        let u = make(http, defaults: d)
        await u.checkIfDue()
        #expect(u.state == .idle)
        #expect(http.count == 1)
        // A failed check is not recorded, so the next call retries.
        await u.checkIfDue()
        #expect(http.count == 2)
    }

    @Test func manualFailureShowsFailed() async {
        let (d, n) = makeDefaults(); defer { d.removePersistentDomain(forName: n) }
        let u = make(FakeHTTP(), defaults: d)
        await u.checkNow()
        #expect(u.state == .failed)
    }

    @Test func cachedReleaseRestoredOnLaunch() async {
        let (d, n) = makeDefaults(); defer { d.removePersistentDomain(forName: n) }
        let http = FakeHTTP(); http.body = releaseJSON("v1.2.0")
        let first = make(http, defaults: d)
        await first.checkNow()
        var fired = 0
        let second = make(FakeHTTP(), defaults: d)
        second.onNewRelease = { _ in fired += 1 }
        guard case .available(let r) = second.state else { Issue.record("state \(second.state)"); return }
        #expect(r.version == v("1.2.0"))
        #expect(fired == 0)
        // Cache older than the running app is ignored.
        let third = make(FakeHTTP(), current: "1.3.0", defaults: d)
        #expect(third.state == .idle)
    }

    @Test func dismissHidesBannerForThatVersionOnly() async {
        let (d, n) = makeDefaults(); defer { d.removePersistentDomain(forName: n) }
        let http = FakeHTTP(); http.body = releaseJSON("v1.2.0")
        let u = make(http, defaults: d)
        await u.checkNow()
        u.dismissBanner()
        #expect(u.bannerRelease == nil)
        if case .available = u.state {} else { Issue.record("still available") }
        http.body = releaseJSON("v1.3.0")
        await u.checkNow()
        #expect(u.bannerRelease?.version == v("1.3.0"))
    }

    @Test func notifiesOncePerVersion() async {
        let (d, n) = makeDefaults(); defer { d.removePersistentDomain(forName: n) }
        let http = FakeHTTP(); http.body = releaseJSON("v1.2.0")
        let u = make(http, defaults: d)
        var seen: [AppVersion] = []
        u.onNewRelease = { seen.append($0.version) }
        await u.checkNow()
        await u.checkNow()
        #expect(seen == [v("1.2.0")])
        http.body = releaseJSON("v1.3.0")
        await u.checkNow()
        #expect(seen == [v("1.2.0"), v("1.3.0")])
        // A new instance on the same defaults does not notify again.
        let again = make(http, defaults: d)
        var fired = 0
        again.onNewRelease = { _ in fired += 1 }
        await again.checkNow()
        #expect(fired == 0)
    }
}
