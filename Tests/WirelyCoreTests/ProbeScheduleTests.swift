import Foundation
import Testing
@testable import WirelyCore

private let targetAddress = "192.0.2.7"

private struct Reply {
    var at: TimeInterval
    var kind: ICMPAnswer.Kind
    var from: String
}

private func router(_ ttl: Int, at: TimeInterval) -> Reply {
    Reply(at: at, kind: .timeExceeded, from: "203.0.113.\(ttl)")
}

private func destination(at: TimeInterval) -> Reply {
    Reply(at: at, kind: .echoReply, from: targetAddress)
}

/// Runs a schedule against a scripted network: `reply` says if and when the probe for (ttl, round) sent at
/// `sentAt` is answered. Probes go out 2 ms apart, like the tracer.
private struct Simulation {
    var collector = TraceCollector()
    var schedule = ProbeSchedule()
    var sends: [(round: Int, ttls: [Int], at: TimeInterval)] = []
    var finishedAt: TimeInterval = 0

    init(schedule: ProbeSchedule = ProbeSchedule(), reply: (_ ttl: Int, _ round: Int, _ sentAt: TimeInterval) -> Reply?) {
        self.schedule = schedule
        var pending: [(seq: UInt16, reply: Reply)] = []
        var lastAnswerAt: TimeInterval?
        var now: TimeInterval = 0

        func deliver(upTo t: TimeInterval) {
            for item in pending.filter({ $0.reply.at <= t }).sorted(by: { $0.reply.at < $1.reply.at }) {
                collector.received(ICMPAnswer(kind: item.reply.kind, from: item.reply.from, seq: item.seq),
                                   at: item.reply.at, target: targetAddress)
                lastAnswerAt = item.reply.at
            }
            pending.removeAll { $0.reply.at <= t }
        }

        for _ in 0..<1000 {
            switch self.schedule.next(now: now, collector: collector, lastAnswerAt: lastAnswerAt) {
            case .send(let round, let ttls):
                sends.append((round, ttls, now))
                for (index, ttl) in ttls.enumerated() {
                    let sentAt = now + 0.002 * Double(index)
                    collector.sent(ttl: ttl, round: round, at: sentAt)
                    if let r = reply(ttl, round, sentAt) {
                        pending.append((TraceCollector.seq(ttl: ttl, round: round), r))
                    }
                }
                now += 0.002 * Double(max(0, ttls.count - 1))
                deliver(upTo: now)
            case .wait(let until):
                #expect(until > now)
                let nextEvent = pending.map(\.reply.at).min() ?? until
                now = min(until, max(nextEvent, now))
                deliver(upTo: now)
            case .finish:
                finishedAt = now
                return
            }
        }
        Issue.record("schedule did not finish")
    }

    func ttls(ofRound round: Int) -> [Int]? { sends.first { $0.round == round }?.ttls }
    func sentAt(round: Int) -> TimeInterval? { sends.first { $0.round == round }?.at }
}

@Test func normalPathFinishesFast() {
    // Five hops, the fifth is the target; round trips of 20-40 ms in round 0, a flat 30 ms in round 2.
    let sim = Simulation { ttl, round, sentAt in
        if round == 2 { return ttl < 5 ? router(ttl, at: sentAt + 0.030) : destination(at: sentAt + 0.030) }
        let delay = 0.020 + 0.005 * Double(min(ttl, 5) - 1)
        return ttl < 5 ? router(ttl, at: sentAt + delay) : destination(at: sentAt + delay)
    }
    #expect(sim.sends.map(\.round) == [0, 2])
    #expect(sim.ttls(ofRound: 2) == [1, 2, 3, 4, 5])
    #expect(sim.sentAt(round: 2)! < 0.1)
    #expect(sim.finishedAt < 0.3)
    #expect(sim.collector.reached)
    let hops = sim.collector.hops()
    #expect(hops.map(\.ttl) == [1, 2, 3, 4, 5])
    // The smaller of the two rounds: the 20 ms round-0 answer for TTL 1, the 30 ms round-2 answer for TTL 4.
    #expect(abs(hops[0].rttMs! - 20) < 0.001)
    #expect(abs(hops[3].rttMs! - 30) < 0.001)
}

@Test func delayedFirstBurstGetsMeasuredAgain() {
    // The user's line: TTL 1 answers at once, everything beyond is held ~1 s and released together.
    // Routers at TTL 2, 4, 5, 7-10; the target answers only the probe at TTL 23 in the first rounds.
    let routers: Set<Int> = [2, 4, 5, 7, 8, 9, 10]
    let sim = Simulation { ttl, round, sentAt in
        if round == 2 {
            if ttl <= 10 { return router(ttl, at: sentAt + 0.012) }
            return destination(at: sentAt + 0.012)
        }
        if ttl == 1 { return router(1, at: sentAt + 0.0036) }
        if routers.contains(ttl) { return router(ttl, at: 1.038 - 0.00001 * Double(ttl)) }
        if ttl == 23 { return destination(at: 1.038) }
        return nil
    }
    #expect(sim.sends.map(\.round) == [0, 1, 2])
    #expect(sim.ttls(ofRound: 2) == Array(1...23))
    let measureAt = sim.sentAt(round: 2)!
    #expect(measureAt >= 1.03 && measureAt < 1.06)
    #expect(sim.finishedAt < 1.2)
    #expect(sim.collector.reached)
    let hops = sim.collector.hops()
    #expect(hops.map(\.ttl) == Array(1...11))
    #expect(hops.last?.isDestination == true)
    #expect(abs(hops[0].rttMs! - 3.6) < 0.001)
    for ttl in routers {
        #expect(abs(hops[ttl - 1].rttMs! - 12) < 0.001)
    }
}

@Test func silentTargetMeasuresUpToLastAnswer() {
    // Routers 1-9 answer after ~30 ms; the target never does.
    let sim = Simulation { ttl, _, sentAt in
        ttl <= 9 ? router(ttl, at: sentAt + 0.030) : nil
    }
    #expect(sim.sends.map(\.round) == [0, 1, 2])
    #expect(sim.ttls(ofRound: 2) == Array(1...9))
    // Round 0 takes ~60 ms to send; the last answer comes ~46 ms in, so quiet starts ~0.35 s.
    #expect(sim.sentAt(round: 2)! >= 0.3)
    #expect(sim.finishedAt < 0.6)
    #expect(!sim.collector.reached)
    #expect(sim.collector.hops().count == 9)
}

@Test func deadlineAlwaysFinishes() {
    let sim = Simulation { _, _, _ in nil }
    #expect(sim.sends.map(\.round) == [0, 1])
    #expect(sim.ttls(ofRound: 1) == Array(1...30))
    #expect(sim.finishedAt == 3.0)
    #expect(sim.collector.hops().isEmpty)

    // A shorter budget is honoured too.
    let short = Simulation(schedule: ProbeSchedule(deadline: 1.0)) { _, _, _ in nil }
    #expect(short.finishedAt == 1.0)
}

@Test func roundOneOnlyResendsUnanswered() {
    var schedule = ProbeSchedule()
    var c = TraceCollector()
    #expect(schedule.next(now: 0, collector: c, lastAnswerAt: nil) == .send(round: 0, ttls: Array(1...30)))
    for ttl in 1...30 { c.sent(ttl: ttl, round: 0, at: 0) }
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.1", seq: TraceCollector.seq(ttl: 1, round: 0)),
               at: 0.01, target: targetAddress)
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.3", seq: TraceCollector.seq(ttl: 3, round: 0)),
               at: 0.03, target: targetAddress)
    #expect(schedule.next(now: 0.06, collector: c, lastAnswerAt: 0.03) == .wait(until: 0.15))
    #expect(schedule.next(now: 0.15, collector: c, lastAnswerAt: 0.03)
            == .send(round: 1, ttls: [2] + Array(4...30)))
    #expect(c.answered(inRound: 0) == [1, 3])
    #expect(c.answered(inRound: 1).isEmpty)
}
