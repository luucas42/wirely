import Foundation
import Testing
@testable import WirelyApp

struct MACAddressTests {
    @Test func parsesPaddedOctets() throws {
        let mac = try #require(MACAddress("a4:5e:60:00:00:01"))
        #expect(mac.description == "a4:5e:60:00:00:01")
        #expect(mac.oui == "A45E60")
    }

    @Test func parsesSingleDigitOctetsAsArpPrintsThem() throws {
        let mac = try #require(MACAddress("a:b:c:d:e:f"))
        #expect(mac.description == "0a:0b:0c:0d:0e:0f")
        #expect(mac.oui == "0A0B0C")
    }

    @Test func acceptsDashesAndUppercase() {
        #expect(MACAddress("A4-5E-60-00-00-01") == MACAddress("a4:5e:60:0:0:1"))
    }

    @Test func rejectsMalformed() {
        #expect(MACAddress("") == nil)
        #expect(MACAddress("a4:5e:60:00:00") == nil)
        #expect(MACAddress("a4:5e:60:00:00:01:02") == nil)
        #expect(MACAddress("a4:5e:60:00:00:zz") == nil)
        #expect(MACAddress("(incomplete)") == nil)
        #expect(MACAddress("a4:5e:60:000:00:01") == nil)
    }

    @Test func detectsLocallyAdministered() throws {
        #expect(try #require(MACAddress("a2:11:22:33:44:55")).isLocallyAdministered)
        #expect(try #require(MACAddress("2:0:0:0:0:20")).isLocallyAdministered)
        #expect(!(try #require(MACAddress("a4:5e:60:00:00:01")).isLocallyAdministered))
    }

    @Test func detectsMulticastAndBroadcast() throws {
        #expect(try #require(MACAddress("1:0:5e:0:0:fb")).isMulticast)
        #expect(try #require(MACAddress("ff:ff:ff:ff:ff:ff")).isBroadcast)
        #expect(!(try #require(MACAddress("a4:5e:60:00:00:01")).isMulticast))
    }

    @Test func roundTripsThroughJSON() throws {
        let mac = try #require(MACAddress("a4:5e:60:00:00:01"))
        let data = try JSONEncoder().encode([mac])
        #expect(String(decoding: data, as: UTF8.self) == "[\"a4:5e:60:00:00:01\"]")
        #expect(try JSONDecoder().decode([MACAddress].self, from: data) == [mac])
    }
}
