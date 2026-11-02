import Foundation
import WirelyCore

/// Decides when to retry a tunnel that dropped. Pure: the controller feeds it statuses and time.
struct ReconnectPlanner: Equatable {
    /// Seconds to wait before the next attempt; the index is the number of attempts already made, the last one repeats.
    static let delays: [TimeInterval] = [2, 5, 10, 20, 30, 60]

    /// Profile to keep up; set only when a tunnel reaches `.connected`.
    private(set) var target: String?
    /// Attempts made since the drop.
    private(set) var attempts = 0
    /// Due time of the next attempt; nil means nothing is scheduled.
    private(set) var nextAt: Date?
    private(set) var inFlight = false
    private var primed = false

    var isActive: Bool { nextAt != nil || inFlight }

    private var nextDelay: TimeInterval { Self.delays[min(attempts, Self.delays.count - 1)] }

    /// Feeds a helper status. The first call is treated as the launch status.
    mutating func observe(_ status: TunnelStatus, now: Date, enabled: Bool) {
        let isFirst = !primed
        primed = true
        switch status.state {
        case .connected:
            guard let name = status.tunnelName else { return }
            target = name
            attempts = 0
            nextAt = nil
        case .connecting:
            return
        case .failed, .disconnected:
            guard !inFlight else { return }
            if isFirst, target == nil, enabled, status.isBlockedByKillSwitch, let name = status.tunnelName {
                target = name
            }
            guard enabled, let target, nextAt == nil,
                  status.tunnelName == nil || status.tunnelName == target else { return }
            nextAt = now.addingTimeInterval(nextDelay)
        }
    }

    /// A manual connect: only the profile that is already the target stays one.
    mutating func userConnecting(_ name: String) {
        if name != target {
            target = nil
            attempts = 0
        }
        nextAt = nil
    }

    mutating func userDisconnected() {
        target = nil
        attempts = 0
        nextAt = nil
    }

    /// Wake or network up: a pending attempt becomes due now.
    mutating func nudge(now: Date) {
        if nextAt != nil { nextAt = now }
    }

    func due(now: Date) -> String? {
        guard !inFlight, let nextAt, now >= nextAt else { return nil }
        return target
    }

    mutating func attemptStarted() {
        inFlight = true
        attempts += 1
        nextAt = nil
    }

    mutating func attemptFinished(connected: Bool, now: Date) {
        inFlight = false
        if connected {
            attempts = 0
            nextAt = nil
        } else if target != nil {
            nextAt = now.addingTimeInterval(nextDelay)
        }
    }

    /// Setting turned off or target deleted.
    mutating func cancel() {
        target = nil
        attempts = 0
        nextAt = nil
    }
}
