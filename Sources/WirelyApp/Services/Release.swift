import Foundation

/// "v1.2.0", "1.2", "1.10.3" → comparable; nil for anything else. Missing parts compare as 0.
struct AppVersion: Comparable, Codable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let pieces = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(piece) else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    private var padded: [Int] { parts + Array(repeating: 0, count: max(0, 3 - parts.count)) }

    static func == (a: AppVersion, b: AppVersion) -> Bool { a.padded == b.padded }
    static func < (a: AppVersion, b: AppVersion) -> Bool { a.padded.lexicographicallyPrecedes(b.padded) }

    var description: String { padded.map(String.init).joined(separator: ".") }
}

/// One GitHub release as Wirely needs it.
struct ReleaseInfo: Equatable, Codable {
    var version: AppVersion
    var tag: String
    var name: String
    var notes: String
    var pageURL: URL
    var dmgURL: URL?
    var publishedAt: Date?

    private struct Payload: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String?
        let name: String?
        let body: String?
        let html_url: String?
        let draft: Bool?
        let published_at: String?
        let assets: [Asset]?
    }

    /// Reads a GitHub "latest release" response; nil if the tag or page URL is missing, or it is a draft.
    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let p = try? JSONDecoder().decode(Payload.self, from: data),
              p.draft != true,
              let tag = p.tag_name, let version = AppVersion(tag),
              let page = p.html_url, let pageURL = URL(string: page) else { return nil }
        let dmg = p.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browser_download_url) }
        let published = p.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return ReleaseInfo(version: version, tag: tag, name: p.name ?? tag, notes: p.body ?? "",
                           pageURL: pageURL, dmgURL: dmg, publishedAt: published)
    }
}

/// GitHub markdown → simple blocks for the in-app notes view.
enum ReleaseNotes {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case bullet(String)
        case numbered(Int, String)
        case paragraph(String)
        case code(String)
    }

    static func blocks(_ markdown: String, language: AppLanguage) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return parse(section(of: lines, language: language))
    }

    /// Turkish picks the `<details>` block whose summary mentions Türkçe; everything else stops at the first `<details>`.
    private static func section(of lines: [String], language: AppLanguage) -> [String] {
        if language == .tr,
           let summary = lines.firstIndex(where: { $0.contains("<summary") && $0.contains("Türkçe") }) {
            let start = (lines[summary...].firstIndex { $0.contains("</summary>") } ?? summary) + 1
            let rest = lines[start...]
            let end = rest.firstIndex { $0.contains("</details>") } ?? lines.endIndex
            return Array(lines[start..<end])
        }
        let end = lines.firstIndex { $0.contains("<details") } ?? lines.endIndex
        return Array(lines[..<end])
    }

    private static func parse(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for raw in lines {
            if code != nil {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(raw)
                }
                continue
            }
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("<") { continue }
            if line.hasPrefix(">") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[!") { continue }
                if line.isEmpty { flush(); continue }
            }
            if let h = heading(line) { flush(); blocks.append(h); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let (n, text) = numbered(line) { flush(); blocks.append(.numbered(n, text)); continue }
            paragraph.append(line)
        }
        flush()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return .heading(level: min(hashes, 3), text: text)
    }

    private static func numbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return (n, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}
