import SwiftUI
import AppKit
import WirelyCore

/// QA hook: `Wirely --render-previews <dir>` renders the main states to PNGs and exits.
/// Run it from the built `.app` binary so Manrope is found in the bundle.
@MainActor
enum PreviewRenderer {
    static func requestedDirectory() -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-previews"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static let configText = """
    [Interface]
    PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    Address = 10.8.0.2/32, fd00::2/128
    DNS = 1.1.1.1, 9.9.9.9
    PostUp = echo hi

    [Peer]
    PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    Endpoint = vpn.example.com:51820
    AllowedIPs = 0.0.0.0/0, ::/0
    PersistentKeepalive = 25
    """

    private static let istanbul = HomeLocation(city: "Istanbul", point: GeoPoint(lat: 41.01, lon: 28.98))
    private static let exitIP = "203.0.113.10"

    private static func frankfurt(_ now: Date) -> ExitLocation {
        ExitLocation(city: "Frankfurt", countryCode: "DE", point: GeoPoint(lat: 50.11, lon: 8.68), fetchedAt: now)
    }

    private struct Scenario {
        var label: String
        var profiles = ["home", "office", "travel"]
        var broken: String?
        var selected: String? = "home"
        var status: TunnelStatus = .disconnected
        var helper: HelperState = .ready
        var samples = false
        var exit = true
        var locating = false
        var latency: Double?
        var language = AppLanguage.en
        var menuBar = false
    }

    private static func store(for s: Scenario) -> TunnelStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wirely-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in s.profiles {
            try? configText.write(to: dir.appendingPathComponent(name + ".conf"), atomically: true, encoding: .utf8)
        }
        if let b = s.broken {
            try? "[Interface]".write(to: dir.appendingPathComponent(b + ".conf"), atomically: true, encoding: .utf8)
        }
        return TunnelStore(directory: dir)
    }

    private static func controller(_ s: Scenario) -> ConnectionController {
        let c = ConnectionController()
        c.helperState = s.helper
        c.status = s.status
        if s.samples {
            let now = Date()
            var list: [ThroughputSample] = []
            for i in 0..<40 {
                let x = Double(i)
                list.append(ThroughputSample(id: now.addingTimeInterval(x - 40),
                                             rxRate: 2_310_000 + (x == 39 ? 0 : 400_000 * sin(x / 3)),
                                             txRate: 126_000 + (x == 39 ? 0 : 30_000 * cos(x / 3))))
            }
            c.samples = list
        }
        return c
    }

    private static func view(_ s: Scenario, now: Date) -> AnyView {
        let store = store(for: s)
        let controller = controller(s)
        let route = RouteModel(store: store, controller: controller, home: istanbul, live: false)
        route.setPreview(exit: s.exit ? frankfurt(now) : nil, ip: s.exit ? exitIP : nil, locating: s.locating,
                         latency: s.latency, selected: s.selected)
        let l10n = L10n(fixed: s.language)
        if s.menuBar {
            return AnyView(MenuBarView(store: store, controller: controller, route: route)
                .environmentObject(l10n))
        }
        return AnyView(MainView(store: store, controller: controller, route: route)
            .environmentObject(l10n)
            .frame(width: 920, height: 600))
    }

    static func run(into directory: String) {
        let now = Date()
        let name = "home"
        let connected = TunnelStatus(state: .connected, tunnelName: name, interface: "utun4",
                                     connectedAt: now.addingTimeInterval(-2538),
                                     lastHandshake: now.addingTimeInterval(-8),
                                     rxBytes: 184_000_000, txBytes: 12_400_000,
                                     endpoint: "\(exitIP):51820", ignoredKeys: ["PostUp"])
        var noResponse = connected
        noResponse.connectedAt = now.addingTimeInterval(-95)
        noResponse.lastHandshake = nil
        noResponse.rxBytes = 0
        noResponse.txBytes = 148
        let connecting = TunnelStatus(state: .connecting, tunnelName: name, endpoint: "\(exitIP):51820")
        let failed = TunnelStatus(state: .failed, tunnelName: name, message: "Handshake did not complete")

        let scenarios: [Scenario] = [
            Scenario(label: "connected", status: connected, samples: true, latency: 46),
            Scenario(label: "connecting", status: connecting),
            Scenario(label: "idle"),
            Scenario(label: "idle-unknown-exit", exit: false),
            Scenario(label: "noresponse", status: noResponse, samples: true, latency: nil),
            Scenario(label: "failed", status: failed),
            Scenario(label: "invalid", profiles: ["home", "office"], broken: "broken", selected: "broken", exit: false),
            Scenario(label: "empty", profiles: [], selected: nil, exit: false),
            Scenario(label: "helper-setup", helper: .notInstalled),
            Scenario(label: "menubar", status: connected, samples: true, latency: 46, menuBar: true),
        ]

        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for s in scenarios {
            for scheme in [ColorScheme.light, .dark] {
                render(s, scheme: scheme, now: now, into: directory)
            }
        }
        var tr = Scenario(label: "connected-tr", status: connected, samples: true, latency: 46)
        tr.language = .tr
        render(tr, scheme: .dark, now: now, into: directory)

        // Debug: land-mask sanity checks (whole world; Istanbul + Frankfurt framing).
        let l10n = L10n(fixed: .en)
        write(AnyView(WorldDebugView().frame(width: 920, height: 600)), label: "world", scheme: .dark, into: directory)
        write(AnyView(RouteMapView(home: istanbul, exit: frankfurt(now), exitIP: exitIP, phase: .connected)
            .environmentObject(l10n).padding(40).frame(width: 920, height: 600).background(Theme.ground)),
              label: "europe", scheme: .dark, into: directory)
    }

    /// Whole-world dot map (row 0 = 90N, col 0 = 180W) to eyeball the land mask.
    private struct WorldDebugView: View {
        var body: some View {
            let size = CGSize(width: 920, height: 600)
            let frame = MapFrame(points: [GeoPoint(lat: -75, lon: 0), GeoPoint(lat: 75, lon: 0)], size: size,
                                 paddingFraction: 0, minSpanLon: 360)
            let dots = frame.landDots(spacing: 6)
            return Canvas { ctx, _ in
                for p in dots {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)),
                             with: .color(Theme.ink))
                }
            }
            .background(Theme.ground)
        }
    }

    private static func render(_ s: Scenario, scheme: ColorScheme, now: Date, into directory: String) {
        // Theme colours resolve through NSAppearance, not the SwiftUI colour scheme.
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = nil }
        write(view(s, now: now), label: s.label, scheme: scheme, into: directory)
    }

    private static func write(_ content: AnyView, label: String, scheme: ColorScheme, into directory: String) {
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = nil }
        let framed = content
            .environment(\.colorScheme, scheme)
            .environment(\.previewMode, true)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed: \(label)\n".utf8))
            return
        }
        let file = "\(label)-\(scheme == .dark ? "dark" : "light").png"
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
    }
}
