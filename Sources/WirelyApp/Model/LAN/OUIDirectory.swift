import Foundation

/// Manufacturer lookup from the IEEE OUI registry (`AABBCC<TAB>Vendor` per line).
struct OUIDirectory {
    private let table: [String: String]

    /// Lines that are not six hex digits, a tab and a name are skipped.
    init(tsv: String) {
        var table: [String: String] = [:]
        for line in tsv.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard f.count == 2, f[0].count == 6, f[0].allSatisfy(\.isHexDigit) else { continue }
            let name = f[1].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { table[f[0].uppercased()] = name }
        }
        self.table = table
    }

    /// The table shipped in the app bundle (`oui.tsv`); nil when absent, e.g. in tests. Parsing takes a
    /// moment, so call it off the main thread.
    static func loadBundled() -> OUIDirectory? {
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return OUIDirectory(tsv: text)
    }

    var count: Int { table.count }

    /// The vendor, or nil when unknown. A randomised (locally administered) address carries no vendor:
    /// show it as "Private address".
    func vendor(for mac: MACAddress) -> String? {
        mac.isLocallyAdministered ? nil : table[mac.oui]
    }

    /// Words dropped from the end of a registry name.
    private static let suffixes: Set<String> = [
        "inc", "incorporated", "corp", "corporation", "co", "company", "ltd", "limited", "llc", "l.l.c",
        "gmbh", "ag", "bv", "b.v", "sa", "s.a", "srl", "plc", "pte", "technologies", "technology",
    ]

    /// Short display name for a registry entry.
    ///
    /// Commas are dropped and company-form words (`Inc.`, `Co.`, `Ltd`, `GmbH`, `Technologies`...) are
    /// removed from the end ("Huawei Technologies Co.,Ltd" is "Huawei"). A name that is entirely
    /// upper case is title-cased word by word, keeping words of up to three characters upper case
    /// ("TP-LINK TECHNOLOGIES CO.,LTD." is "TP-Link", "ZTE CORPORATION" is "ZTE"). A space is put
    /// before a parenthesis. A name made only of such words is returned as is.
    static func shorten(_ ieeeName: String) -> String {
        let original = ieeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        var spaced = ""
        for ch in original {
            if ch == "(", let last = spaced.last, last != " " { spaced.append(" ") }
            spaced.append(ch == "," ? " " : ch)
        }
        var words = spaced.split(separator: " ").map(String.init)
        while words.count > 1, suffixes.contains(words[words.count - 1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            words.removeLast()
        }
        guard var result = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,")).nilIfEmpty,
              !suffixes.contains(result.lowercased()) else { return original }
        if !original.contains(where: \.isLowercase) { result = titleCased(result) }
        return result
    }

    private static func titleCased(_ s: String) -> String {
        var out = ""
        var word = ""
        func flush() {
            out += word.count <= 3 ? word : word.prefix(1) + word.dropFirst().lowercased()
            word = ""
        }
        for ch in s {
            if ch.isLetter || ch.isNumber { word.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
