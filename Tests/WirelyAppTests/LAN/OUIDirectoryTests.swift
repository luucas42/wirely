import Foundation
import Testing
@testable import WirelyApp

private let table = "A45E60\tApple\nB827EB\tRaspberry Pi\r\nbad line\nXYZ\tShort\n001122\tAcme\n\n"

struct OUIDirectoryTests {
    @Test func looksUpByOUI() throws {
        let dir = OUIDirectory(tsv: table)
        #expect(dir.vendor(for: try #require(MACAddress("a4:5e:60:00:00:01"))) == "Apple")
        #expect(dir.vendor(for: try #require(MACAddress("b8:27:eb:1:2:3"))) == "Raspberry Pi")
        #expect(dir.vendor(for: try #require(MACAddress("0:11:22:33:44:55"))) == "Acme")
    }

    @Test func unknownIsNil() throws {
        #expect(OUIDirectory(tsv: table).vendor(for: try #require(MACAddress("44:55:66:00:00:01"))) == nil)
    }

    @Test func malformedLinesAreSkipped() {
        #expect(OUIDirectory(tsv: table).count == 3)
        #expect(OUIDirectory(tsv: "").count == 0)
    }

    @Test func locallyAdministeredAddressesHaveNoVendor() throws {
        // Even when the table happens to contain the prefix, a randomised address is private.
        let dir = OUIDirectory(tsv: "A25E60\tNobody\n")
        #expect(dir.vendor(for: try #require(MACAddress("a2:5e:60:00:00:01"))) == nil)
    }

    @Test(arguments: [
        ("Apple, Inc.", "Apple"),
        ("Google, Inc.", "Google"),
        ("Espressif Inc.", "Espressif"),
        ("Amazon Technologies Inc.", "Amazon"),
        ("Huawei Technologies Co.,Ltd", "Huawei"),
        ("Philips Lighting BV", "Philips Lighting"),
        ("SAMSUNG ELECTRO-MECHANICS(THAILAND)", "Samsung Electro-Mechanics (Thailand)"),
        ("TP-LINK TECHNOLOGIES CO.,LTD.", "TP-Link"),
        ("LG Electronics (Mobile Communications)", "LG Electronics (Mobile Communications)"),
        ("ZTE CORPORATION", "ZTE"),
        ("Hon Hai Precision Industry Co., Ltd.", "Hon Hai Precision Industry"),
        ("Inc.", "Inc."),
        ("  Murata Manufacturing Co., Ltd.  ", "Murata Manufacturing"),
    ])
    func shortensIEEENames(input: String, expected: String) {
        #expect(OUIDirectory.shorten(input) == expected)
    }
}
