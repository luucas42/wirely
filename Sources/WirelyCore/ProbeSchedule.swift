import Foundation

/// When the route tracer sends which probes. Pure state: the caller passes the clock (seconds since the trace
/// started, which is 0) and the collector, and performs whatever action comes back.
///
/// Round 0 probes every TTL at once. Round 1 re-probes the TTLs that stayed silent. The measure round (round 2)
/// goes out once the picture is settled (the target answered, or answers stopped coming) and re-probes every TTL
/// up to the destination, so round trips are taken from probes that were not held back on the way out. Each
/// TTL keeps its fastest round trip.
public struct ProbeSchedule {
    public enum Action: Equatable {
        case send(round: Int, ttls: [Int])
        case wait(until: TimeInterval)
        case finish
    }

    public let maxTTL: Int
    public let retryAfter: TimeInterval
    public let quietAfter: TimeInterval
    public let measureWait: TimeInterval
    public let deadline: TimeInterval

    private var roundZeroSent = false
    private var roundOneSent = false
    private var measure: (sentAt: TimeInterval, expected: Set<Int>)?

    public init(maxTTL: Int = 30, retryAfter: TimeInterval = 0.15, quietAfter: TimeInterval = 0.3,
                measureWait: TimeInterval = 0.5, deadline: TimeInterval = 3.0) {
        self.maxTTL = maxTTL
        self.retryAfter = retryAfter
        self.quietAfter = quietAfter
        self.measureWait = measureWait
        self.deadline = deadline
    }

    /// The next thing to do at `now`. A `.send` result is recorded as sent at `now`.
    /// `lastAnswerAt` is when the latest answer to any probe arrived, if one has.
    public mutating func next(now: TimeInterval, collector: TraceCollector, lastAnswerAt: TimeInterval?) -> Action {
        if now >= deadline { return .finish }

        if !roundZeroSent {
            roundZeroSent = true
            return .send(round: 0, ttls: Array(1...maxTTL))
        }

        // The measure round re-probes everything, so a later retry round would add nothing.
        if !roundOneSent && measure == nil && now >= retryAfter {
            roundOneSent = true
            let ttls = collector.unansweredTTLs()
            if !ttls.isEmpty { return .send(round: 1, ttls: ttls) }
        }

        let quietAt = Self.quietDeadline(collector: collector, lastAnswerAt: lastAnswerAt, quietAfter: quietAfter)

        if let m = measure {
            if m.expected.isSubset(of: collector.answered(inRound: 2)) || now >= m.sentAt + measureWait {
                return .finish
            }
            return .wait(until: min(deadline, m.sentAt + measureWait))
        }

        if collector.reached || (quietAt.map { now >= $0 } ?? false) {
            let limit = collector.destinationTTL ?? collector.lastAnsweredTTL ?? 1
            let before = collector.answered(inRound: 0).union(collector.answered(inRound: 1))
            measure = (now, before.filter { $0 <= limit })
            return .send(round: 2, ttls: Array(1...limit))
        }

        var wakeAt = deadline
        if !roundOneSent { wakeAt = min(wakeAt, retryAfter) }
        if let quietAt { wakeAt = min(wakeAt, quietAt) }
        return .wait(until: wakeAt)
    }

    /// When answers have been quiet long enough to stop waiting for more. A lone answer from TTL 1 (the home
    /// router) proves nothing about the rest of the path, so it never starts the quiet period.
    private static func quietDeadline(collector: TraceCollector, lastAnswerAt: TimeInterval?,
                                      quietAfter: TimeInterval) -> TimeInterval? {
        guard let lastAnswerAt, (collector.lastAnsweredTTL ?? 0) > 1 else { return nil }
        return lastAnswerAt + quietAfter
    }
}
