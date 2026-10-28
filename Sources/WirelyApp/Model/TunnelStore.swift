import Foundation
import WirelyCore

struct StoredTunnel: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var text: String
    var config: TunnelConfig?
    var error: String?

    static func == (l: StoredTunnel, r: StoredTunnel) -> Bool { l.name == r.name && l.text == r.text }
    func hash(into h: inout Hasher) { h.combine(name); h.combine(text) }
}

enum StoreError: Error, LocalizedError {
    case notFound(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let n): return L10n.shared.format(.errProfileNotFound, n)
        case .io(let m): return L10n.shared.format(.errFileIO, m)
        }
    }
}

@MainActor
final class TunnelStore: ObservableObject {
    @Published private(set) var tunnels: [StoredTunnel] = []
    let directory: URL

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Wirely/Tunnels", isDirectory: true)
    }

    init(directory: URL = TunnelStore.defaultDirectory) {
        self.directory = directory
        reload()
    }

    // MARK: Loading

    func reload() {
        let fm = FileManager.default
        try? ensureDirectory()
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [StoredTunnel] = []
        for url in files where url.pathExtension.lowercased() == "conf" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result.append(Self.makeTunnel(name: url.deletingPathExtension().lastPathComponent, text: text))
        }
        tunnels = Self.sorted(result)
    }

    private static func makeTunnel(name: String, text: String) -> StoredTunnel {
        do {
            return StoredTunnel(name: name, text: text, config: try TunnelConfig.parse(text), error: nil)
        } catch {
            return StoredTunnel(name: name, text: text, config: nil, error: L10n.shared.message(for: error))
        }
    }

    private static func sorted(_ list: [StoredTunnel]) -> [StoredTunnel] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Mutations

    @discardableResult
    func add(name: String, text: String) throws -> StoredTunnel {
        _ = try TunnelConfig.parse(text)
        let unique = TunnelNaming.unique(TunnelNaming.sanitize(name), existing: Set(tunnels.map(\.name)))
        try write(text, name: unique)
        let tunnel = Self.makeTunnel(name: unique, text: text)
        tunnels = Self.sorted(tunnels + [tunnel])
        return tunnel
    }

    func update(name: String, text: String) throws {
        guard tunnels.contains(where: { $0.name == name }) else { throw StoreError.notFound(name) }
        _ = try TunnelConfig.parse(text)
        try write(text, name: name)
        let updated = Self.makeTunnel(name: name, text: text)
        tunnels = tunnels.map { $0.name == name ? updated : $0 }
    }

    func rename(_ name: String, to newName: String) throws {
        guard let old = tunnels.first(where: { $0.name == name }) else { throw StoreError.notFound(name) }
        let others = Set(tunnels.map(\.name)).subtracting([name])
        let target = TunnelNaming.unique(TunnelNaming.sanitize(newName), existing: others)
        if target == name { return }
        try write(old.text, name: target)
        try? FileManager.default.removeItem(at: fileURL(name))
        var renamed = old
        renamed.name = target
        tunnels = Self.sorted(tunnels.filter { $0.name != name } + [renamed])
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: fileURL(name))
        tunnels.removeAll { $0.name == name }
    }

    /// Imports `.conf` files and `.zip` archives. Returns localised error messages for failures.
    func importFiles(_ urls: [URL]) -> [String] {
        var errors: [String] = []
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "conf": importConf(url, errors: &errors)
            case "zip": importZip(url, errors: &errors)
            default: errors.append(L10n.shared.format(.errUnsupportedFile, url.lastPathComponent))
            }
        }
        return errors
    }

    private func importConf(_ url: URL, errors: inout [String]) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            try add(name: url.deletingPathExtension().lastPathComponent, text: text)
        } catch {
            errors.append("\(url.lastPathComponent): \(L10n.shared.message(for: error))")
        }
    }

    private func importZip(_ url: URL, errors: inout [String]) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("wirely-import-\(UUID().uuidString)")
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) } catch {
            errors.append("\(url.lastPathComponent): \(L10n.shared.message(for: error))")
            return
        }
        defer { try? fm.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", url.path, tmp.path]
        p.standardError = Pipe()
        p.standardOutput = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            errors.append("\(url.lastPathComponent): \(L10n.shared.message(for: error))")
            return
        }
        guard p.terminationStatus == 0 else {
            errors.append(L10n.shared.format(.errZipOpen, url.lastPathComponent))
            return
        }
        var confs: [URL] = []
        if let en = fm.enumerator(at: tmp, includingPropertiesForKeys: nil) {
            for case let f as URL in en where f.pathExtension.lowercased() == "conf"
                && !f.pathComponents.contains("__MACOSX") && !f.lastPathComponent.hasPrefix("._") {
                confs.append(f)
            }
        }
        if confs.isEmpty { errors.append(L10n.shared.format(.errNoConfInZip, url.lastPathComponent)) }
        for conf in confs.sorted(by: { $0.path < $1.path }) { importConf(conf, errors: &errors) }
    }

    // MARK: File IO

    private func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name + ".conf")
    }

    private func ensureDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func write(_ text: String, name: String) throws {
        do {
            try ensureDirectory()
            let url = fileURL(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw StoreError.io(error.localizedDescription)
        }
    }
}
