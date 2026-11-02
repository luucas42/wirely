import Testing
import Foundation
@testable import WirelyApp

private func net(_ address: String, _ prefix: Int) -> NetworkInfo {
    NetworkInfo(interface: "en0", name: "home-wifi", address: address, prefix: prefix, router: "192.168.1.1", isWiFi: true)
}

private let size = CGSize(width: 476, height: 518)

struct DeviceMapLayoutTests {
    private func radius(_ p: CGPoint) -> CGFloat {
        hypot(p.x - size.width / 2, p.y - size.height / 2)
    }

    @Test func firstPointIsAtTheTop() {
        for n in [1, 5, 12, 13, 24] {
            let p = DeviceMapLayout.positions(count: n, in: size)[0]
            #expect(abs(p.x - size.width / 2) < 0.001)
            #expect(p.y < size.height / 2)
        }
    }

    @Test func upToTwelveShareOneRing() {
        let pts = DeviceMapLayout.positions(count: 10, in: size)
        #expect(pts.count == 10)
        let expected = min(size.width, size.height) / 2 * 0.66
        #expect(pts.allSatisfy { abs(radius($0) - expected) < 0.01 })
        // clockwise: the second point is to the right of the first
        #expect(pts[1].x > pts[0].x)
    }

    @Test func thirteenToTwentyFourUseTwoRings() {
        for n in [13, 20, 24] {
            let pts = DeviceMapLayout.positions(count: n, in: size)
            #expect(pts.count == n)
            let radii = Set(pts.map { (radius($0) * 10).rounded() })
            #expect(radii.count == 2)
            let sizes = DeviceMapLayout.ringSizes(count: n)
            #expect(sizes.inner + sizes.outer == n)
            #expect(sizes.inner < sizes.outer)
        }
        #expect(DeviceMapLayout.ringSizes(count: 20) == (inner: 7, outer: 13))
    }

    @Test func moreThanTwentyFourAreCapped() {
        #expect(DeviceMapLayout.positions(count: 40, in: size).count == 24)
        #expect(DeviceMapLayout.positions(count: 0, in: size).isEmpty)
        #expect(DeviceMapLayout.positions(count: -3, in: size).isEmpty)
    }

    @Test func outerRingIsShiftedHalfAStep() {
        let n = 20
        let (inner, outer) = DeviceMapLayout.ringSizes(count: n)
        let pts = DeviceMapLayout.positions(count: n, in: size)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let angle = atan2(pts[inner].y - c.y, pts[inner].x - c.x) * 180 / .pi
        #expect(abs(angle - (-90 + 180 / Double(outer))) < 0.01)
    }

    @Test func labelsNeverExceedTheirRoom() {
        let w = DeviceMapLayout.labelWidths(count: 20, in: size)
        #expect(w.count == 20)
        #expect(w.allSatisfy { (48...96).contains($0) })
        #expect(w.first! <= w.last!)   // inner ring is tighter than the outer one
        #expect(DeviceMapLayout.labelWidths(count: 1, in: size) == [96])
        #expect(DeviceMapLayout.labelWidths(count: 10, in: size) == Array(repeating: 96, count: 10))   // one ring: names wrap, not shrink
    }

    @Test func centerLabelNeedsRoomOnTwoRings() {
        #expect(DeviceMapLayout.showsCenterLabel(count: 10, in: CGSize(width: 300, height: 300)))
        #expect(DeviceMapLayout.showsCenterLabel(count: 20, in: CGSize(width: 600, height: 600)))
        #expect(!DeviceMapLayout.showsCenterLabel(count: 20, in: CGSize(width: 410, height: 478)))
    }
}

struct DevicePresentationTests {
    @Test func subnetString() {
        #expect(net("192.168.1.20", 24).subnetString == "192.168.1.0/24")
        #expect(net("192.168.1.200", 25).subnetString == "192.168.1.128/25")
        #expect(net("10.20.30.40", 16).subnetString == "10.20.0.0/16")
        #expect(net("10.20.30.40", 8).subnetString == "10.0.0.0/8")
        #expect(net("10.20.30.40", 0).subnetString == "0.0.0.0/0")
        #expect(net("bad", 24).subnetString == "bad")
    }

    @Test func everyKindHasATitleInBothLanguages() {
        let en = L10n(fixed: .en), tr = L10n(fixed: .tr)
        for kind in DeviceKind.allCases {
            #expect(!kind.title(en).isEmpty && kind.title(en) != "kind\(kind.rawValue)")
            #expect(!kind.title(tr).isEmpty)
        }
        #expect(Set(DeviceKind.allCases.map { $0.title(en) }).count == DeviceKind.allCases.count)
        #expect(DeviceKind.tv.title(tr) == "Televizyon")
    }

    @Test func everyDevicesStringExistsInBothTables() {
        let keys: [L] = L.allCases.filter { $0.rawValue.hasPrefix("dev") || $0.rawValue.hasPrefix("kind") || $0.rawValue.hasPrefix("mode") }
        #expect(keys.count > 30)
        for k in keys {
            #expect(stringsEN[k] != nil, "missing en: \(k)")
            #expect(stringsTR[k] != nil, "missing tr: \(k)")
        }
    }

    @Test func vendorTextFallbacks() throws {
        let en = L10n(fixed: .en)
        var d = LANDevice(ip: "192.168.1.5", mac: try #require(MACAddress("a4:5e:60:00:00:05")), name: "x", kind: .unknown)
        #expect(d.vendorText(en) == "Unknown vendor")
        d.vendor = "Acme"
        #expect(d.vendorText(en) == "Acme")
        d.vendor = nil
        d.mac = try #require(MACAddress("a2:5e:60:00:00:05"))
        #expect(d.vendorText(en) == "Private address")
    }

    @Test func relativeDates() {
        let en = L10n(fixed: .en)
        let now = Date(timeIntervalSince1970: 10_000_000)
        #expect(DeviceFormat.relative(nil, now: now, l10n: en) == "—")
        #expect(DeviceFormat.relative(now.addingTimeInterval(-20), now: now, l10n: en) == "just now")
        #expect(DeviceFormat.relative(now.addingTimeInterval(-3 * 3600), now: now, l10n: en) == "3 hours ago")
        #expect(DeviceFormat.relative(now.addingTimeInterval(-20), now: now, l10n: L10n(fixed: .tr)) == "az önce")
    }
}

@MainActor
struct AppRouterModeTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "router-test-\(UUID().uuidString)")! }

    @Test func defaultsToTunnel() {
        #expect(AppRouter(defaults: suite()).mode == .tunnel)
    }

    @Test func modePersistsInTheGivenDefaults() {
        let d = suite()
        let r = AppRouter(defaults: d)
        r.mode = .devices
        #expect(d.string(forKey: AppRouter.modeKey) == "devices")
        #expect(AppRouter(defaults: d).mode == .devices)
        r.mode = .tunnel
        #expect(AppRouter(defaults: d).mode == .tunnel)
    }

    @Test func nilDefaultsNeverPersistsOrReads() {
        let before = UserDefaults.standard.string(forKey: AppRouter.modeKey)
        let r = AppRouter(defaults: nil)
        #expect(r.mode == .tunnel)
        r.mode = .devices
        #expect(UserDefaults.standard.string(forKey: AppRouter.modeKey) == before)
        #expect(AppRouter(defaults: nil).mode == .tunnel)
    }
}
