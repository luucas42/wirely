import Foundation
import AppKit
import Network
@preconcurrency import WirelyCore

enum HelperState: Equatable { case checking, notInstalled, outdated(Int), ready }

/// Automatic reconnect in progress for `name`, as the UI shows it.
struct ReconnectStatus: Equatable {
    var name: String
    var attempts: Int
    var nextAt: Date?
}

private final class PathState: @unchecked Sendable { var satisfied = true }

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
    /// Non-nil while the planner is waiting to retry or retrying a dropped tunnel.
    @Published var reconnectStatus: ReconnectStatus?

    /// Split-tunnel settings per profile; the views observe this store directly.
    let splitStore: SplitStore
    /// Replaces the helper socket (tests).
    var sendOverride: ((HelperRequest) async -> Result<HelperResponse, HelperClientError>)?

    private let queue = DispatchQueue(label: "wirely.helper-client")
    private let client = HelperClient()
    /// Traces get their own queue and client so a slow one never delays status polls.
    private let traceQueue = DispatchQueue(label: "wirely.helper-trace")
    private let traceClient = HelperClient(timeout: 10)
    private var timer: Timer?
    private var pollInFlight = false
    private var tickCount = 0
    private var detector = ConnectionEventDetector()
    private let notifier = Notifier()
    /// Exit city of the live tunnel for the "Connected to …" body; set by the app root.
    var exitCity: () -> String? = { nil }
    /// Resolves a profile name to its stored tunnel; set by the app root.
    var tunnelNamed: (String) -> StoredTunnel? = { _ in nil }
    private var planner = ReconnectPlanner()
    private var launchConnectDone = false
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastSample: (name: String?, connectedAt: Date?, date: Date, rx: UInt64, tx: UInt64)?

    init(splitStore: SplitStore? = nil) {
        self.splitStore = splitStore ?? SplitStore()
    }

    func start() {
        guard timer == nil else { return }
        Task { await checkHelper() }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconnectNow() }
        }
        let monitor = NWPathMonitor()
        // Only touched on the monitor's serial queue.
        let last = PathState()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            defer { last.satisfied = satisfied }
            guard satisfied, !last.satisfied else { return }
            Task { @MainActor in self?.reconnectNow() }
        }
        monitor.start(queue: DispatchQueue(label: "wirely.path-monitor"))
        pathMonitor = monitor
    }

    private func refreshReconnectStatus() {
        let next: ReconnectStatus? = planner.isActive
            ? planner.target.map { ReconnectStatus(name: $0, attempts: planner.attempts, nextAt: planner.nextAt) }
            : nil
        if reconnectStatus != next { reconnectStatus = next }
    }

    /// Stops automatic retrying; the tunnel stays as it is.
    func cancelReconnect() {
        planner.cancel()
        refreshReconnectStatus()
    }

    /// Makes a pending retry due now (also called on wake and when the network returns).
    func reconnectNow() {
        planner.nudge(now: Date())
        refreshReconnectStatus()
    }

    private func reconnectIfDue() {
        guard !busy, let name = planner.due(now: Date()) else { return }
        guard let t = tunnelNamed(name), t.config != nil else {
            planner.cancel()
            refreshReconnectStatus()
            return
        }
        planner.attemptStarted()
        refreshReconnectStatus()
        Task {
            await connect(t, auto: true)
            planner.attemptFinished(connected: status.state == .connected && status.tunnelName == name, now: Date())
            refreshReconnectStatus()
        }
    }

    /// Once per process, after the first good poll: bring `lastProfile` up if the user asked for it.
    private func connectOnLaunchIfNeeded() {
        guard !launchConnectDone else { return }
        launchConnectDone = true
        guard AppPreferences.connectOnLaunch, status.state == .disconnected,
              let name = AppPreferences.lastProfile, let t = tunnelNamed(name), t.config != nil else { return }
        Task { await connect(t) }
    }

    private func tick() {
        if helperState == .ready {
            tickCount = 0
            poll()
            reconnectIfDue()
            return
        }
        tickCount += 1
        if tickCount % 3 == 0, !busy { Task { await checkHelper() } }
    }

    // MARK: Helper calls

    private func call(_ request: HelperRequest) async -> Result<HelperResponse, HelperClientError> {
        if let sendOverride { return await sendOverride(request) }
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

    /// Traces the route to `target` through the helper (own queue, 10 s timeout).
    func trace(_ target: String) async -> Result<TraceResult, TraceFailure> {
        let client = self.traceClient
        let request = HelperRequest(command: .trace, traceTarget: target)
        let outcome: Result<HelperResponse, HelperClientError> = await withCheckedContinuation { cont in
            traceQueue.async {
                do {
                    cont.resume(returning: .success(try client.send(request)))
                } catch let e as HelperClientError {
                    cont.resume(returning: .failure(e))
                } catch {
                    cont.resume(returning: .failure(.io(error.localizedDescription)))
                }
            }
        }
        switch outcome {
        case .success(let r):
            if r.ok, let result = r.trace { return .success(result) }
            return .failure(TraceFailure(code: r.errorCode, message: Self.describe(r, fallback: .genericError)))
        case .failure(let e):
            if e == .notRunning { helperState = .checking }
            return .failure(TraceFailure(code: nil, message: L10n.shared.describe(e)))
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
                if let s = r.status {
                    apply(s)
                    connectOnLaunchIfNeeded()
                }
            case .failure(.notRunning):
                helperState = .checking
                apply(.disconnected)
            case .failure:
                break // transient; try again on the next tick
            }
        }
    }

    private func apply(_ s: TunnelStatus) {
        let events = detector.update(s, now: Date(), exitCity: exitCity())
        planner.observe(s, now: Date(), enabled: AppPreferences.autoReconnect)
        refreshReconnectStatus()
        for e in events { notifier.post(e, l10n: .shared, reconnecting: planner.isActive) }
        if s.state == .connected, let name = s.tunnelName, AppPreferences.lastProfile != name {
            AppPreferences.lastProfile = name
        }
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

    /// `auto` marks a planner-driven retry: it neither resets the planner nor reports errors.
    func connect(_ tunnel: StoredTunnel, auto: Bool = false) async {
        guard !busy else { return }
        // A service from before exclude mode would ignore the direction and tunnel only the list, so it gets
        // the full tunnel instead (never less protection than asked for) and the app asks for the update.
        let excludeHeldBack = !excludeSupported && splitStore.settings(for: tunnel.name).mode == .excluded
        if !auto {
            planner.userConnecting(tunnel.name)
            refreshReconnectStatus()
        }
        busy = true
        if !auto { lastError = nil }
        defer { busy = false }
        // Replacing a live tunnel tears the old one down: not a drop.
        if status.state == .connected, status.tunnelName != tunnel.name { detector.userRequestedDisconnect() }
        let split = splitStore.settings(for: tunnel.name)
        let request = HelperRequest(command: .up, tunnelName: tunnel.name, config: tunnel.text,
                                    killSwitch: KillSwitchSettings.enabled, allowLAN: KillSwitchSettings.allowLAN,
                                    split: split.mode == .all || excludeHeldBack ? nil : split.expandedRules(for: split.mode),
                                    splitExclude: split.mode == .excluded && !excludeHeldBack ? true : nil)
        switch await call(request) {
        case .success(let r):
            if !r.ok, !auto { lastError = Self.describe(r, fallback: .connectFailed) }
            else if excludeHeldBack, !auto { lastError = L10n.shared(.serviceUpdateNeeded) }
            if let s = r.status { apply(s) }
        case .failure(let e):
            if e == .notRunning { helperState = .checking }
            if !auto { lastError = L10n.shared.describe(e) }
        }
    }

    func disconnect() async {
        guard !busy else { return }
        planner.userDisconnected()
        refreshReconnectStatus()
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

extension ConnectionController {
    /// Addresses learned per domain rule, as the helper reports them.
    var splitCounts: [String: SplitRuleStatus] { status.split ?? [:] }
    /// The local DNS proxy runs (false = site rules are off); nil outside split mode.
    var splitDNSActive: Bool? { status.splitDNS }

    /// First service version that understands `splitExclude`.
    static let excludeMinHelperVersion = 9

    /// False while the installed service is older than exclude mode (the app then asks for an update).
    var excludeSupported: Bool {
        if case .outdated(let v) = helperState, v < Self.excludeMinHelperVersion { return false }
        return true
    }

    /// Saves the mode (and the split direction it names); a connected `tunnel` reconnects to apply it.
    func setSplitMode(_ mode: SplitMode, for tunnel: StoredTunnel) async {
        guard splitStore.settings(for: tunnel.name).mode != mode else { return }
        splitStore.setMode(mode, for: tunnel.name)
        if isOn(tunnel) { await connect(tunnel) }
    }

    /// Adds what was typed to the list shown (an alias such as `youtube.com` adds its group). Adding while
    /// the mode is "all" switches to the remembered split direction.
    func addSplitEntry(_ input: String, for tunnel: StoredTunnel) async -> SplitAddOutcome {
        let s = splitStore.settings(for: tunnel.name)
        let outcome = splitStore.add(input, to: s.activeMode, for: tunnel.name)
        if outcome.succeeded { await applyListChange(for: tunnel, wasMode: s.mode, lastSplit: s.lastSplit) }
        return outcome
    }

    /// Adds the group to the shown list, or removes it when it is already there.
    func toggleGroup(_ id: String, for tunnel: StoredTunnel) async -> SplitToggleOutcome {
        let s = splitStore.settings(for: tunnel.name)
        let outcome = splitStore.toggleGroup(id, in: s.activeMode, for: tunnel.name)
        switch outcome {
        case .added: await applyListChange(for: tunnel, wasMode: s.mode, lastSplit: s.lastSplit)
        case .removed: await pushSplitRules(for: tunnel)
        case .failed: break
        }
        return outcome
    }

    func removeSplitEntry(_ entry: SplitEntry, for tunnel: StoredTunnel) async {
        let s = splitStore.settings(for: tunnel.name)
        splitStore.remove(entry, from: s.activeMode, for: tunnel.name)
        await pushSplitRules(for: tunnel)
    }

    private func applyListChange(for tunnel: StoredTunnel, wasMode: SplitMode, lastSplit: SplitMode) async {
        if wasMode == .all {
            await setSplitMode(lastSplit, for: tunnel)
        } else {
            await pushSplitRules(for: tunnel)
        }
    }

    /// Sends the saved list to the running split tunnel; the saved entries stay even if that fails.
    /// The direction never changes live, so only a list of the running direction is sent.
    private func pushSplitRules(for tunnel: StoredTunnel) async {
        guard state(for: tunnel) == .connected, status.split != nil else { return }
        let s = splitStore.settings(for: tunnel.name)
        guard s.mode != .all, (status.splitExclude ?? false) == (s.mode == .excluded) else { return }
        switch await call(HelperRequest(command: .split, split: s.expandedRules(for: s.mode))) {
        case .success(let r):
            if !r.ok { lastError = Self.describe(r, fallback: .genericError) }
            if let s = r.status { apply(s) }
        case .failure(let e):
            if e == .notRunning { helperState = .checking }
            lastError = L10n.shared.describe(e)
        }
    }
}

extension StoredTunnel {
    var endpointHost: String { config?.peers.first?.endpoint?.host ?? "—" }
}
