import Foundation
import WirelyCore

/// A failed trace, already worded for the user; `code` is the helper's error code, if any.
struct TraceFailure: Error, Equatable {
    var code: String?
    var message: String
}

/// State behind route-trace mode: runs the legs, geolocates the public hops and builds the stations.
/// Dependencies are injected so it can be tested without a helper or a network.
@MainActor
final class TraceModel: ObservableObject {
    enum Phase: Equatable { case idle, running, done, failed(String) }

    typealias Context = (home: HomeLocation?, vpn: ExitLocation?, endpointHost: String?, connected: Bool, latencyMs: Double?)

    /// Route mode is open (the map shows the trace instead of the status card).
    @Published var active = false
    @Published var target = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stations: [TraceStation] = []
    @Published var selected: Int?
    @Published private(set) var hopCount = 0
    @Published private(set) var totalMs: Int?
    /// The last leg's target never answered.
    @Published private(set) var reached = true

    /// At most this many location lookups at once.
    static let maxLookups = 4

    private let trace: @Sendable (String) async -> Result<TraceResult, TraceFailure>
    private let locate: @Sendable (String) async -> ExitLocation?
    private let context: () -> Context
    private var generation = 0

    init(trace: @escaping @Sendable (String) async -> Result<TraceResult, TraceFailure>,
         locate: @escaping @Sendable (String) async -> ExitLocation?,
         context: @escaping () -> Context) {
        self.trace = trace
        self.locate = locate
        self.context = context
    }

    /// Opens route mode; connected with an empty target it shows the path to the VPN server at once.
    func open() {
        active = true
        let ctx = context()
        if ctx.connected, Self.endpointHost(ctx.endpointHost) != nil,
           target.trimmingCharacters(in: .whitespaces).isEmpty {
            Task { await run() }
        }
    }

    /// Leaves route mode; a trace still in flight is discarded.
    func close() {
        generation += 1
        active = false
        phase = .idle
        stations = []
        selected = nil
        hopCount = 0
        totalMs = nil
        reached = true
    }

    func run() async {
        guard phase != .running else { return }
        let ctx = context()
        let name = target.trimmingCharacters(in: .whitespaces)
        var plan: [(kind: TraceLegKind, host: String)] = []
        if ctx.connected, let server = Self.endpointHost(ctx.endpointHost) {
            plan.append((.tunnel, server))
            if !name.isEmpty { plan.append((.open, name)) }
        } else {
            guard !name.isEmpty else {
                stations = []
                selected = nil
                phase = .failed(L10n.shared(.traceNeedTarget))
                return
            }
            plan.append((.direct, name))
        }

        generation += 1
        let mine = generation
        phase = .running
        stations = []
        selected = nil
        hopCount = 0
        totalMs = nil

        var legs: [(kind: TraceLegKind, result: TraceResult)] = []
        for step in plan {
            let outcome = await trace(step.host)
            guard mine == generation else { return }
            switch outcome {
            case .success(let r): legs.append((step.kind, r))
            case .failure(let f):
                phase = .failed(f.message)
                return
            }
        }

        let addresses = Self.addressesToLocate(legs.flatMap { $0.result.hops })
        let found = await lookUp(addresses)
        guard mine == generation else { return }

        let built = RouteStations.build(home: ctx.home, legs: legs, locations: found, vpn: ctx.vpn,
                                        tunnelLatencyMs: ctx.latencyMs, targetName: name)
        stations = built
        selected = built.first { $0.jumpMs != nil }?.id ?? built.last?.id
        hopCount = legs.reduce(0) { $0 + $1.result.hops.count }
        totalMs = built.last?.rttMs.map { Int($0.rounded()) }
        reached = legs.last?.result.reached ?? true
        phase = .done
    }

    // MARK: Helpers

    /// Unique public hop addresses, in path order.
    static func addressesToLocate(_ hops: [TraceHop]) -> [String] {
        var seen = Set<String>()
        return hops.compactMap(\.address).filter { !RouteStations.isNonPublic($0) && seen.insert($0).inserted }
    }

    /// Geolocates `addresses` with a sliding window of `maxLookups`.
    private func lookUp(_ addresses: [String]) async -> [String: ExitLocation] {
        let locate = self.locate
        var found: [String: ExitLocation] = [:]
        await withTaskGroup(of: (String, ExitLocation?).self) { group in
            var next = addresses.makeIterator()
            for _ in 0..<Self.maxLookups {
                guard let a = next.next() else { break }
                group.addTask { (a, await locate(a)) }
            }
            while let (address, loc) = await group.next() {
                if let loc { found[address] = loc }
                if let a = next.next() { group.addTask { (a, await locate(a)) } }
            }
        }
        return found
    }

    /// The IPv4 host of a status endpoint ("203.0.113.5:51820"); nil for IPv6, hostnames or garbage.
    nonisolated static func endpointHost(_ endpoint: String?) -> String? {
        guard var host = endpoint?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        let colons = host.filter { $0 == ":" }.count
        if colons == 1, let i = host.lastIndex(of: ":") { host = String(host[..<i]) }
        else if colons > 1 { return nil }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && UInt8($0) != nil }) else { return nil }
        return host
    }
}
