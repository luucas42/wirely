import Testing
import Foundation
import WirelyCore
@testable import WirelyApp

struct ReconnectPlannerTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    private func up(_ name: String) -> TunnelStatus { TunnelStatus(state: .connected, tunnelName: name) }
    private func failed(_ name: String, killSwitch: Bool? = nil) -> TunnelStatus {
        TunnelStatus(state: .failed, tunnelName: name, killSwitch: killSwitch)
    }
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// A planner that was connected to `home` and then dropped at t0 + 5.
    private func dropped() -> ReconnectPlanner {
        var p = ReconnectPlanner()
        p.observe(up("home"), now: t0, enabled: true)
        p.observe(failed("home"), now: at(5), enabled: true)
        return p
    }

    @Test func dropSchedulesFirstRetryAfterTwoSeconds() {
        let p = dropped()
        #expect(p.due(now: at(6)) == nil)
        #expect(p.due(now: at(7)) == "home")
    }

    @Test func backoffGrowsThenStaysAtSixty() {
        var p = dropped()
        var t = at(7)
        var gaps: [TimeInterval] = []
        for _ in 0..<6 {
            p.attemptStarted()
            p.attemptFinished(connected: false, now: t)
            let next = p.nextAt!
            gaps.append(next.timeIntervalSince(t))
            t = next
        }
        #expect(gaps == [5, 10, 20, 30, 60, 60])
    }

    @Test func userDisconnectNeverReconnects() {
        var p = ReconnectPlanner()
        p.observe(up("home"), now: t0, enabled: true)
        p.userDisconnected()
        p.observe(.disconnected, now: at(1), enabled: true)
        #expect(p.isActive == false)
        #expect(p.target == nil)
    }

    @Test func manualConnectFailureIsNotRetried() {
        var p = ReconnectPlanner()
        p.observe(.disconnected, now: t0, enabled: true)
        p.userConnecting("home")
        p.observe(failed("home"), now: at(1), enabled: true)
        #expect(p.isActive == false)
    }

    @Test func successResetsBackoff() {
        var p = dropped()
        var t = at(7)
        for _ in 0..<3 {
            p.attemptStarted()
            p.attemptFinished(connected: false, now: t)
            t = p.nextAt!
        }
        #expect(p.attempts == 3)
        p.observe(up("home"), now: t, enabled: true)
        #expect(p.attempts == 0)
        p.observe(failed("home"), now: t.addingTimeInterval(10), enabled: true)
        #expect(p.due(now: t.addingTimeInterval(11)) == nil)
        #expect(p.due(now: t.addingTimeInterval(12)) == "home")
    }

    @Test func disabledNeverSchedules() {
        var p = ReconnectPlanner()
        p.observe(up("home"), now: t0, enabled: false)
        p.observe(failed("home"), now: at(5), enabled: false)
        #expect(p.isActive == false)
    }

    @Test func nudgeMakesPendingAttemptDueNow() {
        var p = dropped()
        #expect(p.due(now: at(6)) == nil)
        p.nudge(now: at(6))
        #expect(p.due(now: at(6)) == "home")
    }

    @Test func launchBlockedByKillSwitchIsAdopted() {
        var p = ReconnectPlanner()
        p.observe(failed("home", killSwitch: true), now: t0, enabled: true)
        #expect(p.target == "home")
        #expect(p.due(now: at(1)) == nil)
        #expect(p.due(now: at(2)) == "home")
    }

    @Test func launchPlainFailureIsIgnored() {
        var p = ReconnectPlanner()
        p.observe(failed("home", killSwitch: nil), now: t0, enabled: true)
        #expect(p.isActive == false)
        #expect(p.target == nil)
    }

    @Test func switchingProfilesRetargets() {
        var p = ReconnectPlanner()
        p.observe(up("home"), now: t0, enabled: true)
        p.userConnecting("office")
        p.observe(up("office"), now: at(1), enabled: true)
        p.observe(failed("office"), now: at(5), enabled: true)
        #expect(p.due(now: at(7)) == "office")
    }

    @Test func interimStatusesIgnoredWhileInFlight() {
        var p = dropped()
        p.attemptStarted()
        p.observe(.disconnected, now: at(8), enabled: true)
        #expect(p.nextAt == nil)
        p.attemptFinished(connected: false, now: at(9))
        #expect(p.nextAt != nil)
    }

    @Test func dropOfOtherTunnelIgnored() {
        var p = ReconnectPlanner()
        p.observe(up("home"), now: t0, enabled: true)
        p.observe(failed("office"), now: at(5), enabled: true)
        #expect(p.isActive == false)
    }
}
