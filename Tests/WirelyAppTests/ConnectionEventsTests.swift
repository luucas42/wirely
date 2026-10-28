import Testing
import Foundation
import WirelyCore
@testable import WirelyApp

struct ConnectionEventsTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func up(at: Date, hs: Date?) -> TunnelStatus {
        TunnelStatus(state: .connected, tunnelName: "de", connectedAt: at, lastHandshake: hs)
    }
    private let down = TunnelStatus.disconnected

    @Test func connectNotifiesOnce() {
        var d = ConnectionEventDetector()
        var all = d.update(down, now: t0.addingTimeInterval(-1), exitCity: nil)
        for i in 0..<10 {
            let now = t0.addingTimeInterval(Double(i))
            all += d.update(up(at: t0, hs: now), now: now, exitCity: "Frankfurt")
        }
        #expect(all == [.connected(name: "de", city: "Frankfurt")])
    }

    @Test func userDisconnectIsSilent() {
        var d = ConnectionEventDetector()
        _ = d.update(up(at: t0, hs: t0), now: t0, exitCity: nil)
        d.userRequestedDisconnect()
        #expect(d.update(down, now: t0.addingTimeInterval(1), exitCity: nil).isEmpty)
        #expect(d.update(down, now: t0.addingTimeInterval(2), exitCity: nil).isEmpty)
    }

    @Test func unexpectedDropNotifies() {
        var d = ConnectionEventDetector()
        _ = d.update(up(at: t0, hs: t0), now: t0, exitCity: nil)
        #expect(d.update(down, now: t0.addingTimeInterval(1), exitCity: nil) == [.dropped(name: "de")])
    }

    @Test func noResponseOnceThenRecovered() {
        var d = ConnectionEventDetector()
        _ = d.update(up(at: t0, hs: nil), now: t0, exitCity: nil)
        let late = t0.addingTimeInterval(20)
        #expect(d.update(up(at: t0, hs: nil), now: late, exitCity: nil) == [.noResponse(name: "de")])
        #expect(d.update(up(at: t0, hs: nil), now: late.addingTimeInterval(1), exitCity: nil).isEmpty)
        let later = late.addingTimeInterval(5)
        #expect(d.update(up(at: t0, hs: later), now: later, exitCity: nil) == [.recovered(name: "de")])
        #expect(d.update(up(at: t0, hs: later), now: later.addingTimeInterval(1), exitCity: nil).isEmpty)
    }

    @Test func failedNotifies() {
        var d = ConnectionEventDetector()
        let f = TunnelStatus(state: .failed, tunnelName: "de", message: "boom")
        _ = d.update(down, now: t0.addingTimeInterval(-1), exitCity: nil)
        #expect(d.update(f, now: t0, exitCity: nil) == [.failed(name: "de", message: "boom")])
        #expect(d.update(f, now: t0.addingTimeInterval(1), exitCity: nil).isEmpty)
    }

    @Test func firstObservedStatusIsSilent() {
        var d = ConnectionEventDetector()
        #expect(d.update(up(at: t0, hs: t0), now: t0, exitCity: "X").isEmpty)
        #expect(d.update(up(at: t0, hs: t0), now: t0.addingTimeInterval(1), exitCity: "X").isEmpty)
        #expect(d.update(down, now: t0.addingTimeInterval(2), exitCity: nil) == [.dropped(name: "de")])
    }

    @Test func launchDuringStaleHandshakeIsSilent() {
        var d = ConnectionEventDetector()
        let late = t0.addingTimeInterval(600)
        #expect(d.update(up(at: t0, hs: nil), now: late, exitCity: nil).isEmpty)
        #expect(d.update(up(at: t0, hs: nil), now: late.addingTimeInterval(1), exitCity: nil).isEmpty)
        let fresh = late.addingTimeInterval(5)
        #expect(d.update(up(at: t0, hs: fresh), now: fresh, exitCity: nil).isEmpty)
    }
}
