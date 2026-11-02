import Testing
import Foundation
import WirelyCore
@testable import WirelyApp

/// Records what the fake closures were asked, safely across the model's concurrent lookups.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _traces: [String] = []
    private var _located: [String] = []
    var traces: [String] { lock.withLock { _traces } }
    var located: [String] { lock.withLock { _located } }
    func trace(_ t: String) { lock.withLock { _traces.append(t) } }
    func locate(_ a: String) { lock.withLock { _located.append(a) } }
}

private let home = HomeLocation(city: "Istanbul", point: GeoPoint(lat: 41.0, lon: 28.97))

private func loc(_ city: String, _ lat: Double, _ lon: Double) -> ExitLocation {
    ExitLocation(city: city, countryCode: "XX", point: GeoPoint(lat: lat, lon: lon), fetchedAt: Date(timeIntervalSince1970: 0))
}

private let frankfurt = loc("Frankfurt", 50.1, 8.7)
private let amsterdam = loc("Amsterdam", 52.4, 4.9)
private let sofia = loc("Sofia", 42.7, 23.3)

private func hop(_ ttl: Int, _ address: String?, _ rtt: Double?, dest: Bool = false) -> TraceHop {
    TraceHop(ttl: ttl, address: address, rttMs: rtt, isDestination: dest)
}

private func fakeTrace(_ rec: Recorder) -> @Sendable (String) async -> Result<TraceResult, TraceFailure> {
    { target in
        rec.trace(target)
        if target == "203.0.113.5" {
            return .success(TraceResult(target: target, address: target, hops: [
                hop(1, "192.168.1.1", 1), hop(2, "100.64.0.1", 3), hop(3, "203.0.113.1", 20),
                hop(4, "203.0.113.5", 40, dest: true),
            ], durationMs: 500, reached: true))
        }
        return .success(TraceResult(target: target, address: "198.51.100.9", hops: [
            hop(1, "203.0.113.5", 41), hop(2, "198.51.100.1", 50), hop(3, "198.51.100.9", 55, dest: true),
        ], durationMs: 600, reached: true))
    }
}

private let locations: [String: ExitLocation] = [
    "203.0.113.1": sofia, "203.0.113.5": frankfurt, "198.51.100.1": amsterdam, "198.51.100.9": amsterdam,
]

@MainActor
private func makeModel(_ rec: Recorder, connected: Bool, endpoint: String? = "203.0.113.5",
                        trace: (@Sendable (String) async -> Result<TraceResult, TraceFailure>)? = nil) -> TraceModel {
    TraceModel(
        trace: trace ?? fakeTrace(rec),
        locate: { a in rec.locate(a); return locations[a] },
        context: { (home: home, vpn: frankfurt, endpointHost: endpoint, connected: connected, latencyMs: nil) })
}

@MainActor
struct TraceModelTests {
    @Test func connectedEmptyTargetTracesServerOnly() async {
        let rec = Recorder()
        let m = makeModel(rec, connected: true)
        await m.run()
        #expect(rec.traces == ["203.0.113.5"])
        #expect(m.phase == .done)
        #expect(m.stations.map(\.kind) == [.home, .hop, .vpn])
        #expect(m.hopCount == 4)
        #expect(m.totalMs == 40)
        #expect(m.selected == m.stations.first { $0.jumpMs != nil }?.id)
    }

    @Test func connectedWithTargetMakesTwoLegs() async {
        let rec = Recorder()
        let m = makeModel(rec, connected: true)
        m.target = " example.com "
        await m.run()
        #expect(rec.traces == ["203.0.113.5", "example.com"])
        #expect(m.stations.map(\.city) == ["Istanbul", "Sofia", "Frankfurt", "Amsterdam"])
        #expect(m.stations.map(\.leg) == [.tunnel, .tunnel, .tunnel, .open])
        #expect(m.hopCount == 7)
        #expect(m.totalMs == 55)
        #expect(m.stations.last?.kind == .target)
    }

    @Test func disconnectedNeedsTarget() async {
        let rec = Recorder()
        let m = makeModel(rec, connected: false)
        await m.run()
        #expect(rec.traces.isEmpty)
        #expect(m.phase == .failed(L10n.shared(.traceNeedTarget)))
        m.target = "example.com"
        await m.run()
        #expect(rec.traces == ["example.com"])
        #expect(m.phase == .done)
        #expect(m.stations.allSatisfy { $0.leg == .direct })
    }

    @Test func ipv6EndpointSkipsTunnelLeg() async {
        let rec = Recorder()
        let m = makeModel(rec, connected: true, endpoint: nil)
        m.target = "example.com"
        await m.run()
        #expect(rec.traces == ["example.com"])
        #expect(m.stations.allSatisfy { $0.leg == .direct })
    }

    @Test func failureShowsMessage() async {
        let rec = Recorder()
        let m = makeModel(rec, connected: false) { _ in
            .failure(TraceFailure(code: "trace.resolve", message: "Couldn't find nope.example."))
        }
        m.target = "nope.example"
        await m.run()
        #expect(m.phase == .failed("Couldn't find nope.example."))
        #expect(m.stations.isEmpty)
    }

    @Test func secondRunWhileRunningIsIgnored() async {
        let rec = Recorder()
        let gate = AsyncStream<Void>.makeStream()
        let m = makeModel(rec, connected: false) { target in
            rec.trace(target)
            for await _ in gate.stream { break }
            return .success(TraceResult(target: target, address: "198.51.100.9", hops: [
                hop(1, "198.51.100.9", 20, dest: true),
            ], durationMs: 100, reached: true))
        }
        m.target = "example.com"
        let first = Task { await m.run() }
        // Wait until the first trace is really in flight (phase flips before the closure records it).
        while m.phase != .running || rec.traces.isEmpty { await Task.yield() }
        await m.run()   // ignored: returns at once
        #expect(rec.traces == ["example.com"])
        gate.continuation.yield()
        await first.value
        #expect(m.phase == .done)
        #expect(rec.traces.count == 1)
    }

    @Test func geolocationSkipsPrivateHops() async {
        let rec = Recorder()
        let m = makeModel(rec, connected: true)
        m.target = "example.com"
        await m.run()
        let located = rec.located
        #expect(!located.isEmpty)
        #expect(!located.contains("192.168.1.1"))
        #expect(!located.contains("100.64.0.1"))
        #expect(Set(located).count == located.count)   // each address looked up once
        #expect(Set(located) == ["203.0.113.1", "203.0.113.5", "198.51.100.1", "198.51.100.9"])
    }

    @Test func closeResetsAndOpenAutoRunsWhenConnected() async {
        let rec = Recorder()
        let m = makeModel(rec, connected: true)
        m.open()
        #expect(m.active)
        while m.phase != .done { await Task.yield() }
        #expect(rec.traces == ["203.0.113.5"])
        m.close()
        #expect(!m.active)
        #expect(m.phase == .idle)
        #expect(m.stations.isEmpty)
    }
}
