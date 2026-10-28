import Foundation
import Combine
import WirelyCore

struct HomeLocation: Equatable {
    var city: String
    var point: GeoPoint
}

/// What the status card and the map show for the selected profile.
enum RoutePhase: Equatable {
    case connected, connecting, idle, noResponse, failed, invalid
}

/// Geo state behind the Route Map: home, exit, latency and distance for the selected profile.
/// Lookups run off the main actor and are cancelled when the selection (or its endpoint) changes;
/// the 10 s latency probe runs only while the selected profile is connected. Views only read it.
@MainActor
final class RouteModel: ObservableObject {
    @Published var selectedName: String?
    @Published private(set) var home: HomeLocation?
    @Published private(set) var exit: ExitLocation?
    @Published private(set) var exitIP: String?
    @Published private(set) var locating = false
    @Published private(set) var latencyMs: Double?

    private let store: TunnelStore
    private let controller: ConnectionController
    private let locator = ExitLocator(http: URLSessionHTTPFetcher())
    private var cancellables: Set<AnyCancellable> = []
    private var lookupKey: String?
    private var lookupProfile: String?
    private var wasConnected = false
    private var lookupTask: Task<Void, Never>?
    private var latencyKey: String?
    private var latencyTask: Task<Void, Never>?

    /// `live: false` skips the Combine feed and all network work (previews, tests).
    init(store: TunnelStore, controller: ConnectionController,
         home: HomeLocation? = ZoneTab.current().map { HomeLocation(city: $0.city, point: $0.point) },
         live: Bool = true) {
        self.store = store
        self.controller = controller
        self.home = home
        guard live else { return }
        Publishers.CombineLatest3(store.$tunnels, controller.$status, $selectedName)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tunnels, status, selected in
                self?.refresh(tunnels: tunnels, status: status, selected: selected)
            }
            .store(in: &cancellables)
    }

    deinit {
        lookupTask?.cancel()
        latencyTask?.cancel()
    }

    // MARK: Derived

    var selected: StoredTunnel? { store.tunnels.first { $0.name == selectedName } }

    var distanceKm: Double? {
        guard let home, let exit else { return nil }
        return Geo.distanceKm(home.point, exit.point)
    }

    /// Phase of `tunnel` given the controller's status; `now` drives the no-handshake check.
    static func phase(of tunnel: StoredTunnel?, status: TunnelStatus, now: Date) -> RoutePhase {
        guard let tunnel else { return .idle }
        guard tunnel.config != nil else { return .invalid }
        guard status.tunnelName == tunnel.name else { return .idle }
        switch status.state {
        case .disconnected: return .idle
        case .connecting: return .connecting
        case .failed: return .failed
        case .connected: return handshakeMissing(status, now: now) ? .noResponse : .connected
        }
    }

    /// Connected for 15+ s without a handshake in the last 3 minutes.
    nonisolated static func handshakeMissing(_ s: TunnelStatus, now: Date) -> Bool {
        guard let at = s.connectedAt, now.timeIntervalSince(at) >= 15 else { return false }
        guard let hs = s.lastHandshake else { return true }
        return now.timeIntervalSince(hs) > 180
    }

    /// "host:port", "[v6]:port" or a bare address → host.
    static func host(ofEndpoint s: String) -> String {
        if s.hasPrefix("["), let end = s.firstIndex(of: "]") { return String(s[s.index(after: s.startIndex)..<end]) }
        if s.filter({ $0 == ":" }).count == 1, let i = s.lastIndex(of: ":") { return String(s[..<i]) }
        return s
    }

    // MARK: Feed

    private func refresh(tunnels: [StoredTunnel], status: TunnelStatus, selected: String?) {
        guard let tunnel = tunnels.first(where: { $0.name == selected }), tunnel.config != nil else {
            stopLookup(clear: true)
            stopLatency()
            return
        }
        let active = status.tunnelName == tunnel.name && (status.state == .connected || status.state == .connecting)
        let target = (active ? status.endpoint.map(Self.host(ofEndpoint:)) : nil) ?? tunnel.endpointHost
        startLookup(profile: tunnel.name, host: target, connected: active && status.state == .connected)

        if active && status.state == .connected {
            let dns = tunnel.config?.interface.dnsServers.first?.description
            startLatency(profile: tunnel.name, host: dns ?? "1.1.1.1", port: dns != nil ? 53 : 443)
        } else {
            stopLatency()
        }
    }

    private func startLookup(profile: String, host: String, connected: Bool) {
        let key = "\(profile)|\(host)"
        if key == lookupKey {
            // Same target: a connect transition retries a failed lookup right away.
            if connected, !wasConnected, exit == nil, !locating { launchLookup(key: key, host: host) }
            wasConnected = connected
            return
        }
        wasConnected = connected
        // Same profile, new host (hostname -> connected IP): keep the shown exit while re-checking.
        stopLookup(clear: lookupProfile != profile)
        lookupKey = key
        lookupProfile = profile
        launchLookup(key: key, host: host)
    }

    /// Looks the exit up; on failure retries after 15 s, 60 s, then every 5 min while the key stays current.
    private func launchLookup(key: String, host: String) {
        lookupTask?.cancel()
        locating = true
        let locator = self.locator
        lookupTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                var found: ExitLocation?
                let ip = await HostResolver.resolve(host)
                if let ip { found = await locator.location(for: ip) }
                guard !Task.isCancelled, let self, self.lookupKey == key else { return }
                if let found {
                    self.exit = found
                    self.exitIP = ip
                    self.locating = false
                    return
                }
                self.exit = nil
                self.exitIP = ip
                self.locating = false
                let delays: [UInt64] = [15, 60, 300]
                let wait = delays[min(attempt, delays.count - 1)]
                attempt += 1
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                guard !Task.isCancelled, self.lookupKey == key else { return }
                self.locating = true
            }
        }
    }

    private func stopLookup(clear: Bool) {
        lookupTask?.cancel()
        lookupTask = nil
        lookupKey = nil
        lookupProfile = nil
        wasConnected = false
        locating = false
        if clear { exit = nil; exitIP = nil }
    }

    private func startLatency(profile: String, host: String, port: UInt16) {
        let key = "\(profile)|\(host)|\(port)"
        guard key != latencyKey else { return }
        stopLatency()
        latencyKey = key
        latencyTask = Task { [weak self] in
            while !Task.isCancelled {
                let ms = await LatencyProbe.measure(host: host, port: port)
                guard !Task.isCancelled, let self, self.latencyKey == key else { return }
                self.latencyMs = ms
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private func stopLatency() {
        latencyTask?.cancel()
        latencyTask = nil
        latencyKey = nil
        latencyMs = nil
    }

    // MARK: Previews

    /// Fixed values for `PreviewRenderer`.
    func setPreview(exit: ExitLocation?, ip: String? = nil, locating: Bool = false, latency: Double?,
                    selected: String?) {
        self.exit = exit
        self.exitIP = ip
        self.locating = locating
        self.latencyMs = latency
        self.selectedName = selected
    }
}
