import Foundation
@preconcurrency import WirelyCore

enum HelperState: Equatable { case checking, notInstalled, outdated(Int), ready }

struct ThroughputSample: Identifiable {
    let id: Date
    let rxRate: Double
    let txRate: Double
}

@MainActor
final class ConnectionController: ObservableObject {
    @Published var status: TunnelStatus = .disconnected
    @Published var helperState: HelperState = .checking
    @Published var samples: [ThroughputSample] = []
    @Published var busy = false
    @Published var lastError: String?

    private let queue = DispatchQueue(label: "wirely.helper-client")
    private let client = HelperClient()
    private var timer: Timer?
    private var pollInFlight = false
    private var tickCount = 0
    private var detector = ConnectionEventDetector()
    private let notifier = Notifier()
    /// Exit city of the live tunnel for the "Connected to …" body; set by the app root.
    var exitCity: () -> String? = { nil }
    private var lastSample: (name: String?, connectedAt: Date?, date: Date, rx: UInt64, tx: UInt64)?

    func start() {
        guard timer == nil else { return }
        Task { await checkHelper() }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        if helperState == .ready {
            tickCount = 0
            poll()
            return
        }
        tickCount += 1
        if tickCount % 3 == 0, !busy { Task { await checkHelper() } }
    }

    // MARK: Helper calls

    private func call(_ request: HelperRequest) async -> Result<HelperResponse, HelperClientError> {
        let client = self.client
        return await withCheckedContinuation { cont in
            queue.async {
                do {
                    cont.resume(returning: .success(try client.send(request)))
                } catch let e as HelperClientError {
                    cont.resume(returning: .failure(e))
                } catch {
                    cont.resume(returning: .failure(.io(error.localizedDescription)))
                }
            }
        }
    }

    func checkHelper() async {
        switch await call(HelperRequest(command: .version)) {
        case .failure(.notRunning):
            // A restarting daemon (KeepAlive) leaves its plist in place: stay in .checking.
            let installed = FileManager.default.fileExists(atPath: HelperConstants.plistPath)
            helperState = installed ? .checking : .notInstalled
        case .failure(let e):
            // Helper is there but misbehaving; show the problem and keep checking state.
            helperState = .checking
            lastError = L10n.shared.describe(e)
        case .success(let r):
            if r.helperVersion != HelperConstants.helperVersion {
                helperState = .outdated(r.helperVersion)
            } else {
                helperState = .ready
                lastError = nil
                poll()
            }
        }
    }

    private func poll() {
        guard helperState == .ready, !pollInFlight else { return }
        pollInFlight = true
        Task {
            let result = await call(HelperRequest(command: .status))
            pollInFlight = false
            switch result {
            case .success(let r):
                if let s = r.status { apply(s) }
            case .failure(.notRunning):
                helperState = .checking
                apply(.disconnected)
            case .failure:
                break // transient; try again on the next tick
            }
        }
    }

    private func apply(_ s: TunnelStatus) {
        for e in detector.update(s, now: Date(), exitCity: exitCity()) { notifier.post(e, l10n: .shared) }
        if status != s { status = s }
        guard s.state == .connected || s.state == .connecting else {
            lastSample = nil
            if !samples.isEmpty { samples = [] }
            return
        }
        let now = Date()
        if let prev = lastSample, prev.name == s.tunnelName, prev.connectedAt == s.connectedAt {
            let dt = now.timeIntervalSince(prev.date)
            if dt > 0, s.rxBytes >= prev.rx, s.txBytes >= prev.tx {
                let sample = ThroughputSample(id: now,
                                              rxRate: Double(s.rxBytes - prev.rx) / dt,
                                              txRate: Double(s.txBytes - prev.tx) / dt)
                samples = Array((samples + [sample]).suffix(60))
            }
        } else {
            samples = []
        }
        lastSample = (s.tunnelName, s.connectedAt, now, s.rxBytes, s.txBytes)
    }

    private static func describe(_ r: HelperResponse, fallback: L) -> String {
        guard r.errorCode != nil || r.error != nil else { return L10n.shared(fallback) }
        return L10n.shared.describe(helperErrorCode: r.errorCode, arg: r.errorArg, fallback: r.error)
    }

    // MARK: Actions

    func connect(_ tunnel: StoredTunnel) async {
        guard !busy else { return }
        busy = true
        lastError = nil
        defer { busy = false }
        // Replacing a live tunnel tears the old one down: not a drop.
        if status.state == .connected, status.tunnelName != tunnel.name { detector.userRequestedDisconnect() }
        switch await call(HelperRequest(command: .up, tunnelName: tunnel.name, config: tunnel.text)) {
        case .success(let r):
            if !r.ok { lastError = Self.describe(r, fallback: .connectFailed) }
            if let s = r.status { apply(s) }
        case .failure(let e):
            if e == .notRunning { helperState = .checking }
            lastError = L10n.shared.describe(e)
        }
    }

    func disconnect() async {
        guard !busy else { return }
        busy = true
        lastError = nil
        defer { busy = false }
        detector.userRequestedDisconnect()
        switch await call(HelperRequest(command: .down)) {
        case .success(let r):
            if !r.ok { lastError = Self.describe(r, fallback: .disconnectFailed) }
            if let s = r.status { apply(s) }
        case .failure(let e):
            if e == .notRunning { helperState = .checking }
            lastError = L10n.shared.describe(e)
        }
    }

    func installHelper() async {
        busy = true
        lastError = nil
        defer { busy = false }
        let uid = getuid()
        let outcome: Result<Void, Error> = await withCheckedContinuation { cont in
            queue.async {
                do {
                    try HelperInstaller.install(allowedUID: uid)
                    cont.resume(returning: .success(()))
                } catch {
                    cont.resume(returning: .failure(error))
                }
            }
        }
        if case .failure(let e) = outcome {
            lastError = L10n.shared.message(for: e)
            return
        }
        // Give launchd up to 5 s to bring the daemon up.
        for _ in 0..<10 {
            await checkHelper()
            if helperState == .ready { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}

extension ConnectionController {
    /// State of `tunnel` as the helper reports it; any other tunnel counts as disconnected.
    func state(for tunnel: StoredTunnel) -> TunnelState {
        status.tunnelName == tunnel.name ? status.state : .disconnected
    }

    /// Connected or connecting to `tunnel`.
    func isOn(_ tunnel: StoredTunnel) -> Bool {
        let s = state(for: tunnel)
        return s == .connected || s == .connecting
    }

    var latestRates: (rx: Double, tx: Double) {
        (samples.last?.rxRate ?? 0, samples.last?.txRate ?? 0)
    }

    func toggle(_ tunnel: StoredTunnel) async {
        if isOn(tunnel) { await disconnect() } else { await connect(tunnel) }
    }
}

extension StoredTunnel {
    var endpointHost: String { config?.peers.first?.endpoint?.host ?? "—" }
}
