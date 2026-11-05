import Foundation
import WirelyCore

enum SplitRowKind: Equatable { case domain, address, network, profile, group }

/// One line of the split panel's list, already localised.
struct SplitRow: Identifiable, Equatable {
    let id: String
    let kind: SplitRowKind
    let value: String
    let subtitle: String
    let warning: String?
    let removable: Bool
    /// The user rule behind the row; nil for profile and group rows.
    let rule: SplitRule?
    /// The list entry behind the row (rule or group); nil for profile rows.
    var entry: SplitEntry? = nil
    /// A group's domains, for the expanded view; empty otherwise.
    var domains: [String] = []
}

/// Pure presentation of a profile's split list.
enum SplitRows {
    /// Rows of the list `settings.activeMode` points at (the remembered direction while the mode is "all").
    static func rows(settings: SplitSettings, config: TunnelConfig?, counts: [String: SplitRuleStatus],
                     connected: Bool, splitDNS: Bool?, l10n: L10n = .shared) -> [SplitRow] {
        let excluded = settings.activeMode == .excluded
        let entries = settings.current
        let userRules: [SplitRule] = entries.compactMap { if case .rule(let r) = $0 { return r } else { return nil } }
        // Whether the server accepts an address only matters for what goes INTO the tunnel.
        let uncovered = (excluded ? nil : config).map { SplitCoverage.uncovered(rules: userRules, config: $0) } ?? []
        let dnsOff = connected && splitDNS == false
        var out: [SplitRow] = []

        for entry in entries {
            switch entry {
            case .service(let id):
                guard let group = ServiceGroups.group(id: id) else { continue }
                let routed = group.domains.reduce(0) { $0 + (counts[$1]?.routed ?? 0) }
                var subtitle = l10n.format(.splitGroupSubIdle, group.domains.count)
                var warning: String?
                if dnsOff {
                    warning = l10n(.splitDNSOff)
                } else if connected, routed > 0 {
                    subtitle = l10n.format(excluded ? .splitGroupSubOut : .splitGroupSubIn, group.domains.count, routed)
                }
                out.append(SplitRow(id: "service:\(id)", kind: .group, value: group.name, subtitle: subtitle,
                                    warning: warning, removable: true, rule: nil, entry: entry,
                                    domains: group.domains))
            case .rule(let rule):
                let text = rule.text
                var subtitle: String
                var warning: String?
                let kind: SplitRowKind
                switch rule {
                case .domain:
                    kind = .domain
                    let status = counts[text]
                    if dnsOff {
                        subtitle = l10n(.splitSubDomain)
                        warning = l10n(.splitDNSOff)
                    } else if connected {
                        let routed = status?.routed ?? 0
                        subtitle = routed > 0
                            ? l10n.format(excluded ? .splitSubDomainCountOut : .splitSubDomainCount, routed)
                            : l10n(.splitSubDomainLooking)
                        if let rejected = status?.rejected, rejected > 0 {
                            warning = l10n.format(.splitRejected, rejected)
                        }
                    } else {
                        subtitle = l10n(.splitSubDomain)
                    }
                case .address(let a):
                    kind = .address
                    subtitle = l10n(excluded && a.family == .v4 ? .splitSingleAddressOut : .splitSingleAddress)
                    if excluded, a.family == .v6 { warning = l10n(.splitExcludeIPv6) }
                    if uncovered.contains(rule) { warning = l10n(.splitUncovered) }
                case .network(let n):
                    kind = .network
                    subtitle = networkSubtitle(n, l10n)
                    if excluded, n.address.family == .v6 { warning = l10n(.splitExcludeIPv6) }
                    if uncovered.contains(rule) { warning = l10n(.splitUncovered) }
                }
                out.append(SplitRow(id: "rule:\(text)", kind: kind, value: text, subtitle: subtitle,
                                    warning: warning, removable: true, rule: rule, entry: entry))
            }
        }

        if let config, !excluded {
            let userTexts = Set(userRules.map(\.text))
            for n in SplitCoverage.profileNetworks(config) where !userTexts.contains(n.description) {
                out.append(SplitRow(id: "profile:\(n.description)", kind: .profile, value: n.description,
                                    subtitle: l10n(.splitFromProfile), warning: nil, removable: false, rule: nil))
            }
        }
        return out
    }

    /// The pill text: "All traffic through the tunnel", "Split, 4 targets" or "Tunnel, 3 excluded".
    static func summary(settings: SplitSettings, l10n: L10n = .shared) -> String {
        switch settings.mode {
        case .all: return l10n(.splitSummaryAll)
        case .selected: return l10n.format(.splitSummaryN, settings.rules.count)
        case .excluded: return l10n.format(.splitSummaryExcluded, settings.excluded.count)
        }
    }

    /// The status card's line about the list: which sites skip the tunnel, or that the rest does.
    /// nil in "all" mode and for an empty exclude list.
    static func statusLine(settings: SplitSettings, l10n: L10n = .shared) -> String? {
        switch settings.mode {
        case .all: return nil
        case .selected: return l10n(.splitStatusSelected)
        case .excluded:
            let names = settings.excluded.map(displayName)
            switch names.count {
            case 0: return nil
            case 1: return l10n.format(.splitStatusExclOne, names[0])
            case 2: return l10n.format(.splitStatusExclTwo, names[0], names[1])
            default: return l10n.format(.splitStatusExclMany, names[0], names[1], names.count - 2)
            }
        }
    }

    /// A group's name, or the rule's text.
    static func displayName(_ entry: SplitEntry) -> String {
        switch entry {
        case .rule(let r): return r.text
        case .service(let id): return ServiceGroups.group(id: id)?.name ?? id
        }
    }

    /// Address count with the app language's digit grouping; huge networks just say "Network".
    private static func networkSubtitle(_ n: IPNetwork, _ l10n: L10n) -> String {
        let hostBits = (n.address.family == .v4 ? 32 : 128) - n.prefixLength
        guard hostBits < 25 else { return l10n(.splitNetwork) }
        let f = NumberFormatter()
        f.locale = l10n.locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        let text = f.string(from: NSNumber(value: 1 << hostBits)) ?? String(1 << hostBits)
        return l10n.format(.splitNetworkCount, text)
    }
}
