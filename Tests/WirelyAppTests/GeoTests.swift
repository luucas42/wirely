import Testing
import Foundation
@testable import WirelyApp

struct GeoTests {
    @Test func zoneTabParsesBothFormats() {
        let text = """
        # comment
        TR\t+4101+02858\tEurope/Istanbul
        US\t+404251-0740023\tAmerica/New_York\tEastern
        """
        let m = ZoneTab.parse(text)
        let ist = try! #require(m["Europe/Istanbul"])
        #expect(abs(ist.lat - 41.0167) < 0.001)
        #expect(abs(ist.lon - 28.9667) < 0.001)
        let ny = try! #require(m["America/New_York"])
        #expect(abs(ny.lat - 40.7142) < 0.001)
        #expect(abs(ny.lon - -74.0064) < 0.001)
    }

    @Test func zoneTabParsesCommaSeparatedCountries() {
        let m = ZoneTab.parse("DE,DK\t+5230+01322\tEurope/Berlin\n")
        #expect(m["Europe/Berlin"] != nil)
    }

    @Test func cityNameFromTZ() {
        #expect(ZoneTab.cityName("America/Sao_Paulo") == "Sao Paulo")
        #expect(ZoneTab.cityName("Europe/Istanbul") == "Istanbul")
    }

    @Test func istanbulFrankfurtDistance() {
        let d = Geo.distanceKm(GeoPoint(lat: 41.0082, lon: 28.9784), GeoPoint(lat: 50.1109, lon: 8.6821))
        #expect(abs(d - 1860) < 40)
    }
}
