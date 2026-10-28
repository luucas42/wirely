import Foundation
import WirelyCore

enum ConnectionEvent: Equatable {
    case connected(name: String, city: String?)
    case dropped(name: String)
    case noResponse(name: String)
    case recovered(name: String)
    case failed(name: String, message: String)
}

/// Turns the 1 Hz stream of polled statuses into discrete events, one per transition.
struct ConnectionEventDetector {
    private var state: TunnelState = .disconnected
    private var name: String?
    private var primed = false
    private var noResponseSent = false
    private var noResponseQuiet = false   // stale already at launch: tracked, never announced
    private var userDisconnect = false

    /// Call before the user tears down (or replaces) the live tunnel, so the drop stays silent.
    mutating func userRequestedDisconnect() {
        userDisconnect = true
    }

    mutating func update(_ status: TunnelStatus, now: Date, exitCity: String?) -> [ConnectionEvent] {
        var events: [ConnectionEvent] = []
        let prevState = state, prevName = name
        let tunnel = status.tunnelName ?? prevName ?? ""
        defer {
            state = status.state
            name = status.tunnelName
            primed = true
        }
        // The first status only primes state: a tunnel that was already up when the app launched is not news.
        if !primed {
            if status.state == .connected, RouteModel.handshakeMissing(status, now: now) {
                noResponseSent = true
                noResponseQuiet = true
            }
            return []
        }

        switch status.state {
        case .connected:
            if prevState != .connected || prevName != status.tunnelName {
                events.append(.connected(name: tunnel, city: exitCity))
                noResponseSent = false
                noResponseQuiet = false
                userDisconnect = false
            }
            let missing = RouteModel.handshakeMissing(status, now: now)
            if missing, !noResponseSent {
                noResponseSent = true
                events.append(.noResponse(name: tunnel))
            } else if !missing, noResponseSent {
                noResponseSent = false
                if !noResponseQuiet { events.append(.recovered(name: tunnel)) }
                noResponseQuiet = false
            }
        case .failed:
            if prevState != .failed {
                events.append(.failed(name: tunnel, message: status.message ?? ""))
            }
            noResponseSent = false
            noResponseQuiet = false
            userDisconnect = false
        case .disconnected, .connecting:
            if prevState == .connected, status.state == .disconnected, !userDisconnect {
                events.append(.dropped(name: prevName ?? tunnel))
            }
            if prevState == .connected || status.state == .disconnected { userDisconnect = false }
            noResponseSent = false
            noResponseQuiet = false
        }
        return events
    }
}
