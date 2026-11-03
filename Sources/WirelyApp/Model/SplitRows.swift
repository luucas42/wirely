import Foundation
import WirelyCore

enum SplitRowKind: Equatable { case domain, address, network, profile }

/// One line of the split panel's list, already localised.
struct SplitRow: Identifiable, Equatable {
    let id: String
    let kind: SplitRowKind
    let value: String
    let subtitle: String
    let warning: String?
    let removable: Bool
    /// The user rule behind the row; nil for profile rows.
    let rule: SplitRule?
}

/// Pure presentation of a profile's split list.
enum SplitRows {
    static func rows(settings: SplitSettings, config: TunnelConfig?, counts: [String: SplitRuleStatus],
                     connected: Bool, splitDNS: Bool?, l10n: L10n = .shared) -> [SplitRow] {
        let uncovered = config.map { SplitCoverage.uncovered(rules: settings.rules, config: $0) } ?? []
        let dnsOff = connected && splitDNS == false
        var out: [SplitRow] = []

        for rule in settings.rules {
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
                    subtitle = routed > 0 ? l10n.format(.splitSubDomainCount, routed) : l10n(.splitSubDomainLooking)
                    if let rejected = status?.rejected, rejected > 0 {
                        warning = l10n.format(.splitRejected, rejected)
                    }
                } else {
                    subtitle = l10n(.splitSubDomain)
                }
            case .address:
                kind = .address
                subtitle = l10n(.splitSingleAddress)
                if uncovered.contains(rule) { warning = l10n(.splitUncovered) }
            case .network(let n):
                kind = .network
                subtitle = networkSubtitle(n, l10n)
                if uncovered.contains(rule) { warning = l10n(.splitUncovered) }
            }
            out.append(SplitRow(id: "rule:\(text)", kind: kind, value: text, subtitle: subtitle,
                                warning: warning, removable: true, rule: rule))
        }

        if let config {
            let userTexts = Set(settings.rules.map(\.text))
            for n in SplitCoverage.profileNetworks(config) where !userTexts.contains(n.description) {
                out.append(SplitRow(id: "profile:\(n.description)", kind: .profile, value: n.description,
                                    subtitle: l10n(.splitFromProfile), warning: nil, removable: false, rule: nil))
            }
        }
        return out
    }

    static func summary(settings: SplitSettings, l10n: L10n = .shared) -> String {
        settings.mode == .selected ? l10n.format(.splitSummaryN, settings.rules.count) : l10n(.splitSummaryAll)
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
