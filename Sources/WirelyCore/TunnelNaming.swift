import Foundation

public enum TunnelNaming {
    public static let maxLength = 32

    public static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasSuffix(".conf") { s = String(s.dropLast(5)) }
        s = s.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "I")
        s = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _.-")
        s = String(s.filter { allowed.contains($0) })
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > maxLength {
            s = String(s.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? "tunnel" : s
    }

    public static func unique(_ base: String, existing: Set<String>) -> String {
        let lowered = Set(existing.map { $0.lowercased() })
        if !lowered.contains(base.lowercased()) { return base }
        var n = 2
        while lowered.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}
