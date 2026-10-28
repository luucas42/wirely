import Foundation

enum Formatters {
    private static func number(_ v: Double, fraction: Int, locale: Locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = fraction
        f.maximumFractionDigits = fraction
        f.roundingMode = .halfUp
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    /// 1000-based; whole numbers below MB, one decimal from MB up.
    static func bytes(_ n: UInt64, locale: Locale) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return "\(number(v, fraction: i >= 2 ? 1 : 0, locale: locale)) \(units[i])"
    }

    static func rate(_ bps: Double, locale: Locale) -> String {
        let clamped = max(0, min(bps.isFinite ? bps : 0, Double(UInt64.max / 2)))
        return bytes(UInt64(clamped), locale: locale) + "/s"
    }

    static func elapsed(from: Date, to: Date) -> String {
        let total = max(0, Int(to.timeIntervalSince(from)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func ago(_ d: Date?, now: Date, l10n: L10n) -> String {
        guard let d else { return l10n(.never) }
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return l10n.format(.agoSeconds, s) }
        if s < 3600 { return l10n.format(.agoMinutes, s / 60) }
        return l10n.format(.agoHours, s / 3600)
    }

    static func distance(_ km: Double, locale: Locale) -> String {
        if km < 10 { return "< 10 km" }
        return "≈ \(number(km, fraction: 0, locale: locale)) km"
    }

    static func latency(_ ms: Double?) -> String {
        guard let ms, ms.isFinite else { return "—" }
        return "\(Int(ms.rounded())) ms"
    }
}
