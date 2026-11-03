import Foundation
import WirelyCore

/// Addresses learned from DNS answers, per split rule. Thread-safe (own lock): the DNS proxy's learn hook
/// touches it from its own threads.
public final class SplitRouteTable {
    public static let defaultCap = 256

    private let lock = NSLock()
    private let cap: Int
    private var byRule: [SplitRule: [IPAddress]] = [:]
    private var owners: [IPAddress: Set<SplitRule>] = [:]
    private var rejected: [SplitRule: Set<IPAddress>] = [:]

    public init(cap: Int = SplitRouteTable.defaultCap) {
        self.cap = cap
    }

    /// Records `addresses` for `rule` (duplicates and the per-rule cap respected) and returns the ones no
    /// rule owned before, i.e. the ones that still need a route and a table entry.
    public func learn(rule: SplitRule, addresses: [IPAddress]) -> [IPAddress] {
        lock.lock(); defer { lock.unlock() }
        var mine = byRule[rule] ?? []
        var fresh: [IPAddress] = []
        for a in addresses {
            guard mine.count < cap, !mine.contains(a) else { continue }
            mine.append(a)
            if owners[a, default: []].isEmpty { fresh.append(a) }
            owners[a, default: []].insert(rule)
        }
        byRule[rule] = mine
        return fresh
    }

    /// Drops everything `rule` learned. Returns the addresses no other rule still owns.
    public func forget(rule: SplitRule) -> [IPAddress] {
        lock.lock(); defer { lock.unlock() }
        rejected[rule] = nil
        var gone: [IPAddress] = []
        for a in byRule.removeValue(forKey: rule) ?? [] {
            owners[a]?.remove(rule)
            if owners[a]?.isEmpty ?? true {
                owners[a] = nil
                gone.append(a)
            }
        }
        return gone
    }

    /// Remembers learned addresses that were not routed (outside the peers' AllowedIPs). A set, so the
    /// same address answered again does not inflate the count.
    public func reject(rule: SplitRule, addresses: [IPAddress]) {
        guard !addresses.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        rejected[rule, default: []].formUnion(addresses)
    }

    /// Number of addresses learned for `rule` (== the cap when it is full).
    public func count(for rule: SplitRule) -> Int {
        lock.lock(); defer { lock.unlock() }
        return byRule[rule]?.count ?? 0
    }

    /// Per rule text: routed and rejected counts.
    public var status: [String: SplitRuleStatus] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: SplitRuleStatus] = [:]
        for rule in Set(byRule.keys).union(rejected.keys) {
            out[rule.text] = SplitRuleStatus(routed: byRule[rule]?.count ?? 0, rejected: rejected[rule]?.count ?? 0)
        }
        return out
    }

    /// Every address currently owned by some rule.
    public var allAddresses: [IPAddress] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<IPAddress>()
        return byRule.values.flatMap { $0 }.filter { seen.insert($0).inserted }
    }
}
