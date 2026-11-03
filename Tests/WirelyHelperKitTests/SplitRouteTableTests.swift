import Testing
import Foundation
@testable import WirelyHelperKit
@testable import WirelyCore

private func ip(_ s: String) -> IPAddress { IPAddress(s)! }
private let example = SplitRule.domain("example.com")
private let internalRule = SplitRule.domain("intranet.example.com")

@Test func routeTableLearnReturnsOnlyNewAddresses() {
    let t = SplitRouteTable()
    #expect(t.learn(rule: example, addresses: [ip("198.51.100.1"), ip("198.51.100.2"), ip("198.51.100.1")])
            == [ip("198.51.100.1"), ip("198.51.100.2")])
    #expect(t.learn(rule: example, addresses: [ip("198.51.100.2"), ip("198.51.100.3")]) == [ip("198.51.100.3")])
    #expect(t.count(for: example) == 3)
    #expect(Set(t.allAddresses) == [ip("198.51.100.1"), ip("198.51.100.2"), ip("198.51.100.3")])
    #expect(t.status["example.com"] == SplitRuleStatus(routed: 3, rejected: 0))
}

@Test func routeTableRespectsCapPerRule() {
    let t = SplitRouteTable(cap: 3)
    let many = (1...10).map { ip("203.0.113.\($0)") }
    #expect(t.learn(rule: example, addresses: many) == Array(many.prefix(3)))
    #expect(t.count(for: example) == 3)
    #expect(t.learn(rule: example, addresses: [ip("203.0.113.99")]).isEmpty)
    // Another rule has its own budget.
    #expect(t.learn(rule: internalRule, addresses: [ip("203.0.113.99")]) == [ip("203.0.113.99")])
    #expect(SplitRouteTable().learn(rule: example, addresses: (0..<300).map { ip("10.1.\($0 / 200).\($0 % 200 + 1)") }).count == 256)
}

@Test func routeTableForgetKeepsSharedAddresses() {
    let t = SplitRouteTable()
    _ = t.learn(rule: example, addresses: [ip("198.51.100.1"), ip("198.51.100.2")])
    // 198.51.100.2 is also owned by the second rule, so it is not "new" for it.
    #expect(t.learn(rule: internalRule, addresses: [ip("198.51.100.2"), ip("198.51.100.3")]) == [ip("198.51.100.3")])
    #expect(t.forget(rule: example) == [ip("198.51.100.1")])
    #expect(Set(t.allAddresses) == [ip("198.51.100.2"), ip("198.51.100.3")])
    #expect(t.status["example.com"] == nil)
    #expect(t.forget(rule: internalRule).count == 2)
    #expect(t.allAddresses.isEmpty)
    #expect(t.forget(rule: example).isEmpty)
    // After forgetting, a re-learn counts as new again.
    #expect(t.learn(rule: example, addresses: [ip("198.51.100.1")]) == [ip("198.51.100.1")])
}

@Test func routeTableRejectCountsAppearInStatus() {
    let t = SplitRouteTable()
    _ = t.learn(rule: example, addresses: [ip("198.51.100.1")])
    t.reject(rule: example, count: 2)
    t.reject(rule: internalRule, count: 1)
    t.reject(rule: internalRule, count: 0)
    #expect(t.status == ["example.com": SplitRuleStatus(routed: 1, rejected: 2),
                         "intranet.example.com": SplitRuleStatus(routed: 0, rejected: 1)])
    _ = t.forget(rule: internalRule)
    #expect(t.status["intranet.example.com"] == nil)
}

@Test func routeTableIsThreadSafe() {
    let t = SplitRouteTable()
    DispatchQueue.concurrentPerform(iterations: 8) { i in
        for j in 0..<100 { _ = t.learn(rule: example, addresses: [ip("10.\(i).0.\(j % 250 + 1)")]) }
    }
    #expect(t.count(for: example) == 256)
    #expect(t.allAddresses.count == 256)
}
