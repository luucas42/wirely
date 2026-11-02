import Foundation

/// Guesses what a device is from the little the network tells about it.
///
/// Pure rules, first match wins:
/// 1. the router's address is `router`; this Mac's own address is `computer`
///    (the scanner sets `LANDevice.isRouter` / `isThisMac` from the same two comparisons);
/// 2. the Bonjour `_device-info` model (`iPhone…`, `iPad…`, `AppleTV…`, `Mac…`, `AudioAccessory…`);
/// 3. printer services;
/// 4. services that name the kind outright (`_sonos`, `_amzn-wplay`, `_hue`);
/// 5. hints in the name (iphone, ipad, galaxy tab, tv, playstation, nas, …);
/// 6. casting (`_googlecast`, `_airplay`) is a TV, unless a smart-home vendor says otherwise;
/// 7. `_hap` / `_homekit` is smart home;
/// 8. the vendor (NAS, console, TV and smart-home makers, Amazon is a speaker);
/// 9. file-sharing or SSH is a computer;
/// 10. a randomised MAC with nothing else is most likely a phone.
enum DeviceClassifier {
    private static let printerServices: Set<String> = ["_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp"]
    private static let homeServices: Set<String> = ["_hap._tcp", "_homekit._tcp"]
    private static let castServices: Set<String> = ["_googlecast._tcp", "_airplay._tcp"]
    private static let tvVendors = ["samsung", "lg electronics", "sony", "tcl", "vestel", "philips", "hisense", "panasonic", "sharp",
                                    "roku", "vizio", "toshiba"]
    /// Makers of TVs only; their address alone is enough.
    private static let tvOnlyVendors = ["roku", "vizio", "vestel", "tcl", "hisense"]
    private static let smartHomeVendors = ["signify", "philips lighting", "xiaomi", "tuya", "espressif", "shelly", "ikea", "sonoff"]
    private static let nasVendors = ["synology", "qnap", "western digital"]
    private static let consoleVendors = ["nintendo", "sony interactive"]

    static func classify(ip: String, mac: MACAddress, vendor: String?, services: Set<String>, model: String?,
                         hostName: String?, routerIP: String?, thisIP: String?) -> DeviceKind {
        if ip == routerIP { return .router }
        if ip == thisIP { return .computer }
        if let k = model.flatMap(kind(forModel:)) { return k }
        if !services.isDisjoint(with: printerServices) { return .printer }
        if services.contains("_sonos._tcp") || services.contains("_amzn-wplay._tcp") { return .speaker }
        if services.contains("_hue._tcp") { return .smartHome }
        let v = vendor?.lowercased() ?? ""
        if let k = hostName.flatMap(kind(forName:)) { return k }
        let isSmartHomeVendor = smartHomeVendors.contains { v.contains($0) }
        if !services.isDisjoint(with: castServices), !isSmartHomeVendor {
            if services.contains("_googlecast._tcp") || tvVendors.contains(where: { v.contains($0) }) && !v.contains("lighting") {
                return .tv
            }
        }
        if !services.isDisjoint(with: homeServices) { return .smartHome }
        if nasVendors.contains(where: { v.contains($0) }) { return .nas }
        if consoleVendors.contains(where: { v.contains($0) }) { return .console }
        if isSmartHomeVendor { return .smartHome }
        if tvOnlyVendors.contains(where: { v.contains($0) }) { return .tv }
        if v.contains("amazon") { return .speaker }
        if !services.isDisjoint(with: ["_smb._tcp", "_ssh._tcp"]) { return .computer }
        if mac.isLocallyAdministered { return .phone }
        return .unknown
    }

    private static func kind(forModel model: String) -> DeviceKind? {
        if model.hasPrefix("iPhone") { return .phone }
        if model.hasPrefix("iPad") { return .tablet }
        if model.hasPrefix("AppleTV") { return .tv }
        if model.hasPrefix("AudioAccessory") { return .speaker }
        if model.hasPrefix("AirPort") { return .router }
        if model.hasPrefix("Mac") { return .computer }
        return nil
    }

    private static func kind(forName name: String) -> DeviceKind? {
        let n = name.lowercased()
        let tokens = Set(n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        if has("ipad", "galaxy tab") { return .tablet }
        if has("iphone", "android", "galaxy", "pixel") { return .phone }
        if has("macbook", "imac", "macmini", "mac-mini", "mac mini") { return .computer }
        if has("printer", "laserjet", "deskjet", "officejet") { return .printer }
        if has("playstation", "xbox", "nintendo") || !tokens.isDisjoint(with: ["ps4", "ps5"]) { return .console }
        if has("synology", "diskstation") || tokens.contains("nas") { return .nas }
        if has("echo", "alexa", "homepod", "sonos") { return .speaker }
        if has("vacuum", "roomba") || tokens.contains("hue") { return .smartHome }
        if has("bravia", "chromecast", "roku", "appletv") || tokens.contains("tv") || n.hasSuffix("tv") { return .tv }
        return nil
    }
}
