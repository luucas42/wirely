import Foundation

/// When the route tracer sends which probes. Pure state: the caller passes the clock (seconds since the trace
/// started, which is 0) and the collector, and performs whatever action comes back.
///
/// Round 0 probes every TTL at once and round 1 re-probes the silent ones. Some access lines hold the first
/// probes of a new flow for about a second and release them together, so round trips measured against round 0
/// can be wildly inflated. Measure rounds (2, 3, ...) fix that: whenever answers have settled and some answered
/// TTL has not been probed again since it first answered, or the destination moved, every TTL up to the
/// destination (or the last answer) is probed once more. Each TTL keeps its fastest round trip.
public struct ProbeSchedule {
    public enum Action: Equatable {
        case send(round: Int, ttls: [Int])
        case wait(until: TimeInterval)
        case finish
    }

    public let maxTTL: Int
    public let retryAfter: TimeInterval
    public let settle: TimeInterval
    public let measureWait: TimeInterval
    public let quietAfter: TimeInterval
    public let deadline: TimeInterval
    public let maxMeasureRounds: Int

    /// Highest round number a schedule with `maxMeasureRounds` can send (rounds 0 and 1, then 2...), plus one
    /// spare. Bounds the sequence numbers, and so the UDP destination ports, a trace can use.
    public static func highestRound(maxMeasureRounds: Int = 6) -> Int { 1 + maxMeasureRounds + 1 }

    private var roundZeroSent = false
    private var roundOneSent = false
    private var measureCount = 0
    /// The latest measure round: its number, when it went out, and the TTLs that had answered by then.
    private var lastMeasure: (round: Int, sentAt: TimeInterval, expected: Set<Int>)?
    /// TTLs that a measure round has covered after their first answer.
    private var covered: Set<Int> = []
    private var destinationAtLastMeasure: Int?

    public init(maxTTL: Int = 30, retryAfter: TimeInterval = 0.15, settle: TimeInterval = 0.08,
                measureWait: TimeInterval = 0.5, quietAfter: TimeInterval = 1.2, deadline: TimeInterval = 3.0,
                maxMeasureRounds: Int = 6) {
        self.maxTTL = maxTTL
        self.retryAfter = retryAfter
        self.settle = settle
        self.measureWait = measureWait
        self.quietAfter = quietAfter
        self.deadline = deadline
        self.maxMeasureRounds = maxMeasureRounds
    }

    /// The next thing to do at `now`. A `.send` result is recorded as sent at `now`.
    /// `lastNewAnswerAt` is when the latest news arrived (see `TraceCollector.received`), if any has.
    public mutating func next(now: TimeInterval, collector: TraceCollector,
                              lastNewAnswerAt: TimeInterval?) -> Action {
        if now >= deadline { return .finish }

        if !roundZeroSent {
            roundZeroSent = true
            return .send(round: 0, ttls: Array(1...maxTTL))
        }

        if !roundOneSent && now >= retryAfter {
            roundOneSent = true
            let ttls = collector.unansweredTTLs()
            if !ttls.isEmpty { return .send(round: 1, ttls: ttls) }
        }

        let limit = collector.destinationTTL ?? collector.lastAnsweredTTL
        let canMeasure = measureCount < maxMeasureRounds
        let pending = canMeasure && limit.map { limit in
            !collector.answeredTTLs.filter { $0 <= limit }.isSubset(of: covered)
                || (collector.destinationTTL != nil && collector.destinationTTL != destinationAtLastMeasure)
        } == true

        if pending, let limit, let news = lastNewAnswerAt, now >= news + settle {
            let answered = collector.answeredTTLs.filter { $0 <= limit }
            covered.formUnion(answered)
            destinationAtLastMeasure = collector.destinationTTL
            let round = 2 + measureCount
            measureCount += 1
            lastMeasure = (round, now, answered)
            return .send(round: round, ttls: Array(1...limit))
        }

        var measureSettled = true
        if let m = lastMeasure {
            measureSettled = m.expected.isSubset(of: collector.answered(inRound: m.round))
                || now >= m.sentAt + measureWait
        }
        let quiet = lastNewAnswerAt.map { now >= $0 + quietAfter } ?? false
        if !pending && measureSettled && lastNewAnswerAt != nil && (collector.reached || quiet) {
            return .finish
        }

        var wakeAt = deadline
        func consider(_ t: TimeInterval) { if t > now { wakeAt = min(wakeAt, t) } }
        if !roundOneSent { consider(retryAfter) }
        if let news = lastNewAnswerAt {
            if pending { consider(news + settle) }
            if !collector.reached { consider(news + quietAfter) }
        }
        if let m = lastMeasure, !measureSettled { consider(m.sentAt + measureWait) }
        return .wait(until: wakeAt)
    }
}
