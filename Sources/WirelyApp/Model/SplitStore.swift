import Foundation
import WirelyCore

enum SplitMode: String, Codable, Equatable { case all, selected, excluded }

/// One line of a split list: a site/IP rule, or a whole service group (`service:<id>` in the file).
enum SplitEntry: Hashable, Codable {
    case rule(SplitRule)
    case service(String)

    static let servicePrefix = "service:"

    /// Canonical string used in storage; a group never goes through `SplitRule.parse`.
    var text: String {
        switch self {
        case .rule(let r): return r.text
        case .service(let id): return Self.servicePrefix + id
        }
    }

    /// nil for text that is neither a rule nor a known group.
    init?(text: String) {
        if text.hasPrefix(Self.servicePrefix) {
            let id = String(text.dropFirst(Self.servicePrefix.count))
            guard ServiceGroups.group(id: id) != nil else { return nil }
            self = .service(id)
        } else if case .success(let r) = SplitRule.parse(text) {
            self = .rule(r)
        } else {
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let entry = SplitEntry(text: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid split entry: \(text)"))
        }
        self = entry
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }

    /// The rule texts the helper gets for this entry.
    var expandedRules: [String] {
        switch self {
        case .rule(let r): return [r.text]
        case .service(let id): return ServiceGroups.group(id: id)?.domains ?? []
        }
    }
}

/// One profile's split-tunnel choice: everything through the tunnel, only `rules` through it, or
/// everything except `excluded`. Both lists are kept whichever one is active.
struct SplitSettings: Codable, Equatable {
    var mode: SplitMode = .all
    /// The split direction used when `mode` is `.all` and the user switches back to "Split" (selected|excluded).
    var lastSplit: SplitMode = .selected
    /// The "only selected" list.
    var rules: [SplitEntry] = []
    /// The "everything except" list.
    var excluded: [SplitEntry] = []

    init(mode: SplitMode = .all, lastSplit: SplitMode = .selected,
         rules: [SplitEntry] = [], excluded: [SplitEntry] = []) {
        self.mode = mode
        self.lastSplit = lastSplit == .excluded ? .excluded : .selected
        self.rules = rules
        self.excluded = excluded
    }

    private enum CodingKeys: String, CodingKey { case mode, lastSplit, rules, excluded }

    /// Missing keys take their defaults (a 1.5 file has only `mode` and `rules`); an entry that no
    /// longer parses, or an unknown group, is dropped instead of losing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(SplitMode.self, forKey: .mode)) ?? .all
        let last = (try? c.decode(SplitMode.self, forKey: .lastSplit)) ?? .selected
        lastSplit = last == .excluded ? .excluded : .selected
        rules = Self.entries(c, .rules)
        excluded = Self.entries(c, .excluded)
        if mode != .all { lastSplit = mode }
    }

    private static func entries(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [SplitEntry] {
        ((try? c.decode([String].self, forKey: key)) ?? []).compactMap { SplitEntry(text: $0) }
    }

    /// The list the panel shows: the active direction, or `lastSplit` while the mode is `.all`.
    var activeMode: SplitMode { mode == .all ? lastSplit : mode }
    var current: [SplitEntry] { entries(for: activeMode) }

    func entries(for list: SplitMode) -> [SplitEntry] {
        switch list {
        case .excluded: return excluded
        case .selected: return rules
        case .all: return entries(for: lastSplit)
        }
    }

    mutating func setEntries(_ entries: [SplitEntry], for list: SplitMode) {
        if (list == .all ? lastSplit : list) == .excluded { excluded = entries } else { rules = entries }
    }

    func hasGroup(_ id: String, in list: SplitMode? = nil) -> Bool {
        entries(for: list ?? activeMode).contains(.service(id))
    }

    /// What the helper gets for `list`: rule texts plus every group's domains, without repeats, in order.
    func expandedRules(for list: SplitMode? = nil) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for text in entries(for: list ?? activeMode).flatMap(\.expandedRules) where seen.insert(text).inserted {
            out.append(text)
        }
        return out
    }

    /// A service group offered for what is being typed; nil once it is in the list.
    func suggestion(for draft: String) -> ServiceGroup? {
        guard let g = ServiceGroups.suggestion(for: draft), !hasGroup(g.id) else { return nil }
        return g
    }
}

enum SplitAddError: Error, Equatable {
    case invalid(SplitRuleError)
    case duplicate(String)
    case full

    /// `list` picks the wording of "not a host": the exclude list also takes service names.
    func message(_ l10n: L10n = .shared, list: SplitMode = .selected) -> String {
        switch self {
        case .invalid(.notAnAddress): return l10n(.splitErrNotAnAddress)
        case .invalid(.badPrefix): return l10n(.splitErrBadPrefix)
        case .invalid(.notAHost): return l10n(list == .excluded ? .splitErrNotAHostExcluded : .splitErrNotAHost)
        case .duplicate(let text): return l10n.format(.splitErrDuplicate, text)
        case .full: return l10n(.splitErrFull)
        }
    }
}

/// What `SplitStore.add` did with what was typed.
enum SplitAddOutcome: Equatable {
    case added
    /// A service name or domain was typed: the whole group was added instead.
    case addedGroup(name: String, typed: String)
    case failed(SplitAddError)

    var error: SplitAddError? {
        if case .failed(let e) = self { return e }
        return nil
    }

    var succeeded: Bool { error == nil }

    /// The note under the input after an automatic group; nil otherwise.
    func note(_ l10n: L10n = .shared) -> String? {
        guard case .addedGroup(let name, let typed) = self else { return nil }
        return l10n.format(.splitAutoGroupNote, typed, name)
    }
}

enum SplitToggleOutcome: Equatable {
    case added, removed
    case failed(SplitAddError)
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
        if mode != .all { s.lastSplit = mode }
        store(s, for: profile)
    }

    /// Adds `input` at the top of `list` (`.all` = the remembered direction). A dotted service name such as
    /// `youtube.com` adds its group instead.
    @discardableResult
    func add(_ input: String, to list: SplitMode, for profile: String) -> SplitAddOutcome {
        var s = settings(for: profile)
        let entry: SplitEntry
        var group: ServiceGroup?
        if let g = ServiceGroups.exactAlias(input) {
            entry = .service(g.id)
            group = g
        } else {
            switch SplitRule.parse(input) {
            case .success(let r): entry = .rule(r)
            case .failure(let e): return .failed(.invalid(e))
            }
        }
        var entries = s.entries(for: list)
        if entries.contains(entry) {
            return .failed(.duplicate(group?.name ?? entry.text))
        }
        if entries.count >= Self.maxRules { return .failed(.full) }
        entries.insert(entry, at: 0)
        s.setEntries(entries, for: list)
        store(s, for: profile)
        if let group { return .addedGroup(name: group.name, typed: input.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return .added
    }

    /// Adds a rule to the list that is active now. Returns why it was refused, or nil.
    @discardableResult
    func add(_ input: String, for profile: String) -> SplitAddError? {
        add(input, to: settings(for: profile).activeMode, for: profile).error
    }

    /// Adds the group if it isn't in `list`, removes it if it is.
    @discardableResult
    func toggleGroup(_ id: String, in list: SplitMode, for profile: String) -> SplitToggleOutcome {
        guard ServiceGroups.group(id: id) != nil else { return .failed(.invalid(.notAHost)) }
        var s = settings(for: profile)
        var entries = s.entries(for: list)
        if let i = entries.firstIndex(of: .service(id)) {
            entries.remove(at: i)
            s.setEntries(entries, for: list)
            store(s, for: profile)
            return .removed
        }
        if entries.count >= Self.maxRules { return .failed(.full) }
        entries.insert(.service(id), at: 0)
        s.setEntries(entries, for: list)
        store(s, for: profile)
        return .added
    }

    func remove(_ entry: SplitEntry, from list: SplitMode, for profile: String) {
        var s = settings(for: profile)
        var entries = s.entries(for: list)
        entries.removeAll { $0 == entry }
        s.setEntries(entries, for: list)
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
