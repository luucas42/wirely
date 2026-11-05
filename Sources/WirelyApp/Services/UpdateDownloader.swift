import Foundation
import AppKit
import CryptoKit
import CoreServices

/// Fetches a file to a temporary location, reporting progress (0…1, nil when the size is unknown).
protocol UpdateFileFetching: Sendable {
    func download(_ url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL
}

/// URLSession download with a delegate for progress. Redirects (GitHub → CDN) are followed by default.
struct URLSessionUpdateFetcher: UpdateFileFetching {
    func download(_ url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let task = DownloadTask(progress: progress)
        return try await task.run(url)
    }

    private final class DownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let progress: @Sendable (Double?) -> Void
        private var continuation: CheckedContinuation<URL, Error>?

        init(progress: @escaping @Sendable (Double?) -> Void) { self.progress = progress }

        func run(_ url: URL) async throws -> URL {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 60
            cfg.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            var req = URLRequest(url: url)
            req.setValue("Wirely/1.0", forHTTPHeaderField: "User-Agent")
            return try await withCheckedThrowingContinuation { cont in
                continuation = cont
                session.downloadTask(with: req).resume()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
            progress(expected > 0 ? min(1, Double(written) / Double(expected)) : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                finish(.failure(URLError(.badServerResponse)))
                return
            }
            // The system deletes `location` when this returns, so move it first.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("wirely-update-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                finish(.success(kept))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
        }

        private func finish(_ result: Result<URL, Error>) {
            guard let cont = continuation else { return }
            continuation = nil
            cont.resume(with: result)
        }
    }
}

/// Downloads the update DMG inside the app, checks its SHA-256, saves it to Downloads and opens it.
/// Without a published checksum nothing is downloaded in-app; the release page opens instead.
@MainActor
final class UpdateDownloader: ObservableObject {
    enum Failure: Equatable { case network, checksum, save }

    enum State: Equatable {
        case idle
        case downloading(version: String, fraction: Double?)
        case verifying(version: String)
        case done(version: String, file: URL)
        case failed(version: String, Failure)

        /// The release version this state belongs to; nil for `.idle`.
        var version: String? {
            switch self {
            case .idle: return nil
            case .downloading(let v, _), .verifying(let v), .done(let v, _), .failed(let v, _): return v
            }
        }
    }

    @Published private(set) var state: State = .idle
    /// The running download, kept so tests can await it.
    private(set) var task: Task<Void, Never>?

    private let fetcher: UpdateFileFetching
    private let downloads: URL
    private let openURL: (URL) -> Void

    init(fetcher: UpdateFileFetching = URLSessionUpdateFetcher(), downloads: URL? = nil,
         open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.fetcher = fetcher
        self.downloads = downloads
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        self.openURL = open
    }

    /// The state as the UI of `release` should see it: other versions' states read as idle.
    func state(for release: ReleaseInfo) -> State {
        state.version == release.version.description ? state : .idle
    }

    func start(_ release: ReleaseInfo) {
        switch state {
        case .downloading, .verifying: return
        default: break
        }
        guard let dmg = release.dmgURL, let expected = release.dmgSHA256 else {
            openURL(release.pageURL)
            return
        }
        let version = release.version.description
        state = .downloading(version: version, fraction: nil)
        task = Task { await run(release, dmg: dmg, expected: expected, version: version) }
    }

    /// Re-opens a finished download.
    func open(_ file: URL) { openURL(file) }

    /// Fixed state for `PreviewRenderer`.
    func setPreview(_ state: State) { self.state = state }

    private func run(_ release: ReleaseInfo, dmg: URL, expected: String, version: String) async {
        let temp: URL
        do {
            temp = try await fetcher.download(dmg) { [weak self] fraction in
                Task { @MainActor [weak self] in self?.progress(fraction, version: version) }
            }
        } catch {
            state = .failed(version: version, .network)
            return
        }

        state = .verifying(version: version)
        let actual = await Task.detached { try? Self.sha256(of: temp) }.value
        guard actual == expected else {
            try? FileManager.default.removeItem(at: temp)
            state = .failed(version: version, .checksum)
            return
        }

        let name = dmg.lastPathComponent.lowercased().hasSuffix(".dmg") ? dmg.lastPathComponent : "Wirely-\(version).dmg"
        let target = downloads.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temp, to: target)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            state = .failed(version: version, .save)
            return
        }

        Self.quarantine(target, dmg: dmg, page: release.pageURL)
        state = .done(version: version, file: target)
        openURL(target)
    }

    private func progress(_ fraction: Double?, version: String) {
        guard case .downloading(let v, _) = state, v == version else { return }
        state = .downloading(version: version, fraction: fraction)
    }

    /// Marks the file like a browser download so Gatekeeper still checks it on first launch. Failures are ignored.
    private static func quarantine(_ file: URL, dmg: URL, page: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Wirely",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
            kLSQuarantineDataURLKey as String: dmg,
            kLSQuarantineOriginURLKey as String: page,
        ]
        var url = file
        try? url.setResourceValues(values)
    }

    /// Streamed, so a large DMG never sits in memory.
    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
