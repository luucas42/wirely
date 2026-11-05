import Testing
import Foundation
import CryptoKit
@testable import WirelyApp

private final class FakeFetcher: UpdateFileFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _temp: URL?
    var contents = Data("dmg-bytes".utf8)
    var fails = false
    /// Reports 0.5, then waits for `release()` before returning.
    var gated = false
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    var calls: Int { lock.withLock { _calls } }
    var temp: URL? { lock.withLock { _temp } }

    func release() {
        lock.lock()
        released = true
        let g = gate
        gate = nil
        lock.unlock()
        g?.resume()
    }

    func download(_ url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        lock.withLock { _calls += 1 }
        if fails { throw URLError(.cannotConnectToHost) }
        progress(0.5)
        if gated {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released { lock.unlock(); c.resume() } else { gate = c; lock.unlock() }
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wirely-test-\(UUID().uuidString)")
        try contents.write(to: file)
        lock.withLock { _temp = file }
        return file
    }
}

private final class Opened: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.withLock { _urls } }
    func add(_ u: URL) { lock.withLock { _urls.append(u) } }
}

private func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private let pageURL = URL(string: "https://github.com/example/app/releases/tag/v9.9.9")!
private let dmgURL = URL(string: "https://github.com/example/app/releases/download/v9.9.9/Wirely-9.9.9.dmg")!

private func release(sha: String?, dmg: URL? = dmgURL) -> ReleaseInfo {
    ReleaseInfo(version: AppVersion("9.9.9")!, tag: "v9.9.9", name: "Wirely 9.9.9", notes: "", pageURL: pageURL,
                dmgURL: dmg, dmgSHA256: sha, publishedAt: nil)
}

private func scratchDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wirely-dl-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
struct UpdateDownloaderTests {
    private func make(_ fetcher: FakeFetcher, _ opened: Opened, _ dir: URL) -> UpdateDownloader {
        UpdateDownloader(fetcher: fetcher, downloads: dir, open: { opened.add($0) })
    }

    @Test func successSavesQuarantinesAndOpens() async throws {
        let fetcher = FakeFetcher(), opened = Opened(), dir = scratchDir()
        let d = make(fetcher, opened, dir)
        d.start(release(sha: sha(fetcher.contents)))
        await d.task?.value

        let saved = dir.appendingPathComponent("Wirely-9.9.9.dmg")
        #expect(d.state == .done(version: "9.9.9", file: saved))
        #expect(try Data(contentsOf: saved) == fetcher.contents)
        #expect(opened.urls == [saved])
        let values = try saved.resourceValues(forKeys: [.quarantinePropertiesKey])
        #expect(values.quarantineProperties != nil)
        #expect(fetcher.temp.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func existingFileIsReplaced() async throws {
        let fetcher = FakeFetcher(), opened = Opened(), dir = scratchDir()
        let saved = dir.appendingPathComponent("Wirely-9.9.9.dmg")
        try Data("old".utf8).write(to: saved)
        let d = make(fetcher, opened, dir)
        d.start(release(sha: sha(fetcher.contents)))
        await d.task?.value
        #expect(try Data(contentsOf: saved) == fetcher.contents)
        #expect(d.state == .done(version: "9.9.9", file: saved))
    }

    @Test func checksumMismatchDeletesAndDoesNotOpen() async throws {
        let fetcher = FakeFetcher(), opened = Opened(), dir = scratchDir()
        let d = make(fetcher, opened, dir)
        d.start(release(sha: sha(Data("something else".utf8))))
        await d.task?.value
        #expect(d.state == .failed(version: "9.9.9", .checksum))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(fetcher.temp.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(opened.urls.isEmpty)
    }

    @Test func fetchErrorIsNetworkFailure() async {
        let fetcher = FakeFetcher(), opened = Opened(), dir = scratchDir()
        fetcher.fails = true
        let d = make(fetcher, opened, dir)
        d.start(release(sha: sha(fetcher.contents)))
        await d.task?.value
        #expect(d.state == .failed(version: "9.9.9", .network))
        #expect(opened.urls.isEmpty)
    }

    @Test func unwritableDownloadsIsSaveFailure() async throws {
        let fetcher = FakeFetcher(), opened = Opened()
        let blocker = scratchDir().appendingPathComponent("file")
        try Data().write(to: blocker)
        let d = make(fetcher, opened, blocker.appendingPathComponent("Downloads"))
        d.start(release(sha: sha(fetcher.contents)))
        await d.task?.value
        #expect(d.state == .failed(version: "9.9.9", .save))
        #expect(opened.urls.isEmpty)
    }

    @Test func missingChecksumOpensReleasePage() {
        let fetcher = FakeFetcher(), opened = Opened()
        let d = make(fetcher, opened, scratchDir())
        d.start(release(sha: nil))
        #expect(opened.urls == [pageURL])
        #expect(d.state == .idle)
        #expect(fetcher.calls == 0)
        d.start(release(sha: sha(Data()), dmg: nil))
        #expect(opened.urls == [pageURL, pageURL])
        #expect(fetcher.calls == 0)
    }

    @Test func secondStartWhileDownloadingIsIgnored() async {
        let fetcher = FakeFetcher(), opened = Opened()
        fetcher.gated = true
        let d = make(fetcher, opened, scratchDir())
        let r = release(sha: sha(fetcher.contents))
        d.start(r)
        d.start(r)
        fetcher.release()
        await d.task?.value
        #expect(fetcher.calls == 1)
        #expect(opened.urls.count == 1)
    }

    @Test func progressReachesState() async {
        let fetcher = FakeFetcher(), opened = Opened()
        fetcher.gated = true
        let d = make(fetcher, opened, scratchDir())
        d.start(release(sha: sha(fetcher.contents)))
        for _ in 0..<200 where d.state != .downloading(version: "9.9.9", fraction: 0.5) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(d.state == .downloading(version: "9.9.9", fraction: 0.5))
        fetcher.release()
        await d.task?.value
    }

    @Test func otherVersionsReadAsIdle() {
        let d = make(FakeFetcher(), Opened(), scratchDir())
        d.setPreview(.failed(version: "9.9.9", .network))
        #expect(d.state(for: release(sha: nil)) == .failed(version: "9.9.9", .network))
        var other = release(sha: nil)
        other.version = AppVersion("10.0.0")!
        #expect(d.state(for: other) == .idle)
    }
}
