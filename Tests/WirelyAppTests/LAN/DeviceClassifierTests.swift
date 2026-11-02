import Testing
@testable import WirelyApp

private let routerIP = "192.168.1.1"
private let thisIP = "192.168.1.10"

private func kind(ip: String = "192.168.1.50", mac: String = "a4:5e:60:00:00:50", vendor: String? = nil,
                  services: Set<String> = [], model: String? = nil, name: String? = nil) -> DeviceKind {
    DeviceClassifier.classify(ip: ip, mac: MACAddress(mac)!, vendor: vendor, services: services, model: model,
                              hostName: name, routerIP: routerIP, thisIP: thisIP)
}

struct DeviceClassifierTests {
    @Test func gatewayIsRouter() {
        #expect(kind(ip: routerIP, vendor: "Apple", model: "iPhone15,2") == .router)
    }

    @Test func thisAddressIsComputer() {
        #expect(kind(ip: thisIP, services: ["_ipp._tcp"]) == .computer)
    }

    @Test func appleModelsMapToKinds() {
        #expect(kind(model: "iPhone15,2") == .phone)
        #expect(kind(model: "iPad13,4") == .tablet)
        #expect(kind(model: "AppleTV11,1") == .tv)
        #expect(kind(model: "MacBookPro18,3") == .computer)
        #expect(kind(model: "Macmini9,1") == .computer)
        #expect(kind(model: "AudioAccessory5,1") == .speaker)
    }

    @Test func printerServices() {
        #expect(kind(services: ["_ipp._tcp", "_printer._tcp"]) == .printer)
        #expect(kind(services: ["_pdl-datastream._tcp"], name: "HP LaserJet") == .printer)
    }

    @Test func printerBeatsGenericVendor() {
        #expect(kind(vendor: "Samsung", services: ["_ipps._tcp"]) == .printer)
    }

    @Test func castWithTVVendorIsTV() {
        #expect(kind(vendor: "Samsung", services: ["_airplay._tcp"]) == .tv)
        #expect(kind(vendor: "LG Electronics", services: ["_googlecast._tcp"]) == .tv)
        #expect(kind(services: ["_googlecast._tcp"]) == .tv)
    }

    @Test func philipsLightingIsNotATV() {
        #expect(kind(vendor: "Philips Lighting", services: ["_hap._tcp"]) == .smartHome)
    }

    @Test func smartHomeByServiceAndVendor() {
        #expect(kind(services: ["_hue._tcp"], name: "Hue Bridge") == .smartHome)
        #expect(kind(vendor: "Espressif") == .smartHome)
        #expect(kind(vendor: "Shelly") == .smartHome)
        #expect(kind(vendor: "Tuya") == .smartHome)
    }

    @Test func speakers() {
        #expect(kind(services: ["_sonos._tcp"]) == .speaker)
        #expect(kind(services: ["_amzn-wplay._tcp"]) == .speaker)
        #expect(kind(vendor: "Amazon") == .speaker)
        #expect(kind(name: "Echo Dot") == .speaker)
    }

    @Test func nameHints() {
        #expect(kind(name: "Barış's iPhone") == .phone)
        #expect(kind(name: "iPad") == .tablet)
        #expect(kind(name: "Pixel-8") == .phone)
        #expect(kind(name: "Galaxy Tab S9") == .tablet)
        #expect(kind(name: "Living Room TV") == .tv)
        #expect(kind(name: "living-room-tv") == .tv)
        #expect(kind(name: "PlayStation-5") == .console)
        #expect(kind(name: "xbox") == .console)
        #expect(kind(name: "Robot vacuum") == .smartHome)
        #expect(kind(name: "DiskStation") == .nas)
    }

    @Test func watches() {
        #expect(kind(model: "Watch6,1") == .watch)
        #expect(kind(name: "Watch") == .watch)
        #expect(kind(name: "Apple-Watch") == .watch)
        #expect(kind(name: "applewatch") == .watch)
        // a randomised address would otherwise fall back to phone
        #expect(kind(mac: "a2:11:22:33:44:55", name: "Watch") == .watch)
        #expect(kind(mac: "a2:11:22:33:44:55", model: "Watch6,1") == .watch)
    }

    @Test func moreSmartHome() {
        #expect(kind(vendor: "Hangzhou BroadLink") == .smartHome)
        #expect(kind(vendor: "broadlink") == .smartHome)
        for name in ["Wellbeing-Test", "Bedroom-Aircon", "Salon klima", "Air Purifier", "Hall Thermostat"] {
            #expect(kind(name: name) == .smartHome, "\(name)")
        }
        #expect(kind(mac: "a2:11:22:33:44:55", name: "Bedroom-Aircon") == .smartHome)
    }

    @Test func modelBeatsNameHint() {
        #expect(kind(model: "iPad13,4", name: "Living Room TV") == .tablet)
    }

    @Test func nasAndConsoleVendors() {
        #expect(kind(vendor: "Synology", services: ["_smb._tcp"]) == .nas)
        #expect(kind(vendor: "Nintendo") == .console)
    }

    @Test func sharingServicesMeanComputer() {
        #expect(kind(services: ["_ssh._tcp"]) == .computer)
    }

    @Test func randomisedAddressFallsBackToPhone() {
        #expect(kind(mac: "a2:11:22:33:44:55") == .phone)
        #expect(kind(mac: "a2:11:22:33:44:55", name: "Living Room TV") == .tv)
    }

    @Test func nothingKnownIsUnknown() {
        #expect(kind() == .unknown)
        #expect(kind(vendor: "Apple") == .unknown)
    }

    @Test func symbolsAreDistinctPerKind() {
        #expect(DeviceKind.router.symbol == "wifi.router")
        #expect(DeviceKind.unknown.symbol == "questionmark.circle")
        #expect(Set(DeviceKind.allCases.map(\.symbol)).count == DeviceKind.allCases.count)
    }
}
