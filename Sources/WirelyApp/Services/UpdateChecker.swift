import Foundation

/// Asks GitHub for the latest Wirely release at most once a day and keeps the result for the UI.
/// Automatic checks fail silently; only a manual check reports `.failed`.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable { case idle, checking, upToDate, available(ReleaseInfo), failed }

    static let latestURL = URL(string: "https://api.github.com/repos/luucas42/wirely/releases/latest")!
    static let interval: TimeInterval = 86_400

    @Published private(set) var state: State = .idle
    /// Called once per version, when a check finds a release newer than the running app.
    var onNewRelease: ((ReleaseInfo) -> Void)?

    private let http: HTTPFetching
    private let current: AppVersion
    private let defaults: UserDefaults
    private let now: () -> Date

    private enum Key {
        static let auto = "checkForUpdates"
        static let lastCheck = "updateLastCheck"
        static let cached = "updateCachedRelease"
        static let dismissed = "updateDismissedVersion"
        static let notified = "updateNotifiedVersion"
    }

    init(http: HTTPFetching = URLSessionHTTPFetcher(), current: AppVersion,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.http = http
        self.current = current
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Key.cached),
           let release = try? JSONDecoder().decode(ReleaseInfo.self, from: data),
           release.version > current {
            state = .available(release)
        }
    }

    var autoCheck: Bool {
        get { defaults.object(forKey: Key.auto) as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.auto) }
    }

    /// The available release, unless the user dismissed that version.
    var bannerRelease: ReleaseInfo? {
        guard case .available(let release) = state,
              defaults.string(forKey: Key.dismissed) != release.version.description else { return nil }
        return release
    }

    func checkIfDue() async {
        guard autoCheck, state != .checking else { return }
        if let last = defaults.object(forKey: Key.lastCheck) as? Date,
           now().timeIntervalSince(last) < Self.interval { return }
        await run(manual: false)
    }

    func checkNow() async {
        guard state != .checking else { return }
        await run(manual: true)
    }

    func dismissBanner() {
        guard case .available(let release) = state else { return }
        objectWillChange.send()
        defaults.set(release.version.description, forKey: Key.dismissed)
    }

    /// Fixed state for `PreviewRenderer`.
    func setPreview(_ state: State) { self.state = state }

    private func run(manual: Bool) async {
        let previous = state
        state = .checking
        guard let data = try? await http.get(Self.latestURL, timeout: 15),
              let release = ReleaseInfo.parse(data) else {
            state = manual ? .failed : previous
            return
        }
        defaults.set(now(), forKey: Key.lastCheck)
        if let encoded = try? JSONEncoder().encode(release) { defaults.set(encoded, forKey: Key.cached) }
        guard release.version > current else {
            state = .upToDate
            return
        }
        state = .available(release)
        let version = release.version.description
        if defaults.string(forKey: Key.notified) != version {
            defaults.set(version, forKey: Key.notified)
            onNewRelease?(release)
        }
    }
}
