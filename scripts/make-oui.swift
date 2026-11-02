#!/usr/bin/env swift
// Builds Resources/oui.tsv (`AABBCC<TAB>Short Vendor`, sorted) from the IEEE MA-L registry.
//
//   curl -fsSL https://standards-oui.ieee.org/oui/oui.csv -o oui.csv
//   swift scripts/make-oui.swift oui.csv Resources/oui.tsv
//
// A script cannot import the app target, so `shorten` below is a copy of OUIDirectory.shorten
// (Sources/WirelyApp/Model/LAN/OUIDirectory.swift). Keep the two identical.
import Foundation

let suffixes: Set<String> = [
    "inc", "incorporated", "corp", "corporation", "co", "company", "ltd", "limited", "llc", "l.l.c",
    "gmbh", "ag", "bv", "b.v", "sa", "s.a", "srl", "plc", "pte", "technologies", "technology",
]

func shorten(_ ieeeName: String) -> String {
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
    let joined = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
    guard !joined.isEmpty, !suffixes.contains(joined.lowercased()) else { return original }
    var result = joined
    if !original.contains(where: \.isLowercase) { result = titleCased(result) }
    return result
}

func titleCased(_ s: String) -> String {
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

/// RFC 4180 parser: quoted fields may hold commas, doubled quotes and line breaks.
func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var chars = text.unicodeScalars.makeIterator()
    var pending: Unicode.Scalar? = chars.next()
    while let c = pending {
        pending = chars.next()
        if quoted {
            if c == "\"" {
                if pending == "\"" { field.unicodeScalars.append("\""); pending = chars.next() } else { quoted = false }
            } else { field.unicodeScalars.append(c) }
        } else if c == "\"" { quoted = true }
        else if c == "," { row.append(field); field = "" }
        else if c == "\n" || c == "\r" {
            if c == "\r", pending == "\n" { pending = chars.next() }
            row.append(field); field = ""
            rows.append(row); row = []
        } else { field.unicodeScalars.append(c) }
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows
}

let args = CommandLine.arguments
guard args.count == 3, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    FileHandle.standardError.write(Data("usage: make-oui.swift <ieee-oui.csv> <out.tsv>\n".utf8))
    exit(2)
}

var table: [String: String] = [:]
for row in parseCSV(text).dropFirst() where row.count >= 3 {
    let code = row[1].uppercased()
    let name = row[2].trimmingCharacters(in: .whitespacesAndNewlines)
    guard code.count == 6, code.allSatisfy(\.isHexDigit), !name.isEmpty, name.lowercased() != "private" else { continue }
    let short = shorten(name).replacingOccurrences(of: "\t", with: " ")
    table[code] = short
}
let out = table.keys.sorted().map { "\($0)\t\(table[$0]!)" }.joined(separator: "\n") + "\n"
try out.write(toFile: args[2], atomically: true, encoding: .utf8)
print("\(table.count) entries -> \(args[2])")
