import Testing
import Foundation
@testable import WirelyApp

struct FormatterTests {
    let en = Locale(identifier: "en_US")
    let tr = Locale(identifier: "tr_TR")

    @Test func bytesFormatting() {
        #expect(Formatters.bytes(0, locale: en) == "0 B")
        #expect(Formatters.bytes(856_000, locale: en) == "856 KB")
        #expect(Formatters.bytes(1_234_000_000, locale: en) == "1.2 GB")
        #expect(Formatters.bytes(1_234_000_000, locale: tr) == "1,2 GB")
        #expect(Formatters.rate(2_000_000, locale: en) == "2.0 MB/s")
    }

    @Test func distanceFormatting() {
        #expect(Formatters.distance(1860.4, locale: en) == "≈ 1,860 km")
        #expect(Formatters.distance(1860.4, locale: tr) == "≈ 1.860 km")
        #expect(Formatters.distance(3, locale: en) == "< 10 km")
    }

    @Test func latencyAndElapsed() {
        #expect(Formatters.latency(46.2) == "46 ms")
        #expect(Formatters.latency(nil) == "—")
        let t = Date(timeIntervalSince1970: 0)
        #expect(Formatters.elapsed(from: t, to: t.addingTimeInterval(2538)) == "00:42:18")
    }

    @Test func agoLocalized() {
        let now = Date()
        let en = L10n(fixed: .en), tr = L10n(fixed: .tr)
        #expect(Formatters.ago(now.addingTimeInterval(-8), now: now, l10n: en) == "8 s ago")
        #expect(Formatters.ago(now.addingTimeInterval(-8), now: now, l10n: tr) == "8 sn önce")
        #expect(Formatters.ago(nil, now: now, l10n: en) == "Never")
        #expect(Formatters.ago(nil, now: now, l10n: tr) == "Henüz yok")
    }
}
