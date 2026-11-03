import Foundation
import WirelyCore

enum SplitMode: String, Codable, Equatable { case all, selected }

/// One profile's split-tunnel choice: everything through the tunnel, or only `rules`.
struct SplitSettings: Codable, Equatable {
    var mode: SplitMode = .all
    var rules: [SplitRule] = []

    init(mode: SplitMode = .all, rules: [SplitRule] = []) {
        self.mode = mode
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey { case mode, rules }

    /// A rule that no longer parses is dropped instead of losing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(SplitMode.self, forKey: .mode)) ?? .all
        let texts = (try? c.decode([String].self, forKey: .rules)) ?? []
        rules = texts.compactMap { if case .success(let r) = SplitRule.parse($0) { return r } else { return nil } }
    }
}

enum SplitAddError: Error, Equatable {
    case invalid(SplitRuleError)
    case duplicate(String)
    case full

    func message(_ l10n: L10n = .shared) -> String {
        switch self {
        case .invalid(.notAnAddress): return l10n(.splitErrNotAnAddress)
        case .invalid(.badPrefix): return l10n(.splitErrBadPrefix)
        case .invalid(.notAHost): return l10n(.splitErrNotAHost)
        case .duplicate(let text): return l10n.format(.splitErrDuplicate, text)
        case .full: return l10n(.splitErrFull)
        }
    }
}

/// Split-tunnel settings of every profile, kept in `split.json` next to the profiles.
@MainActor
final class SplitStore: ObservableObject {
    static let maxRules = 200

    @Published private(set) var all: [String: SplitSettings]
    let url: URL

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Wirely/split.json")
    }

    init(url: URL = SplitStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: SplitSettings].self, from: data) {
            all = decoded
        } else {
            all = [:]
        }
    }

    func settings(for profile: String) -> SplitSettings { all[profile] ?? SplitSettings() }

    func setMode(_ mode: SplitMode, for profile: String) {
        var s = settings(for: profile)
        s.mode = mode
        store(s, for: profile)
    }

    /// Adds a rule at the top of the list. Returns why it was refused, or nil.
    @discardableResult
    func add(_ input: String, for profile: String) -> SplitAddError? {
        let rule: SplitRule
        switch SplitRule.parse(input) {
        case .success(let r): rule = r
        case .failure(let e): return .invalid(e)
        }
        var s = settings(for: profile)
        if s.rules.contains(rule) { return .duplicate(rule.text) }
        if s.rules.count >= Self.maxRules { return .full }
        s.rules.insert(rule, at: 0)
        store(s, for: profile)
        return nil
    }

    func remove(_ rule: SplitRule, for profile: String) {
        var s = settings(for: profile)
        s.rules.removeAll { $0 == rule }
        store(s, for: profile)
    }

    func renameProfile(_ old: String, to new: String) {
        guard old != new, let s = all[old] else { return }
        all[old] = nil
        all[new] = s
        save()
    }

    func deleteProfile(_ name: String) {
        guard all[name] != nil else { return }
        all[name] = nil
        save()
    }

    // MARK: File IO

    /// Default settings are not kept in the file.
    private func store(_ s: SplitSettings, for profile: String) {
        all[profile] = s == SplitSettings() ? nil : s
        save()
    }

    private func save() {
        let fm = FileManager.default
        do {
            let dir = url.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(all)
            guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Settings stay in memory for this run; the next change tries the file again.
        }
    }
}
