import Foundation

public enum ZoneTab {
    /// Parses tzdata `zone.tab` / `zone1970.tab` text into tz id → coordinates.
    public static func parse(_ text: String) -> [String: GeoPoint] {
        var out: [String: GeoPoint] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") { continue }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3, let p = coordinates(String(cols[1])) else { continue }
            out[String(cols[2])] = p
        }
        return out
    }

    /// Last path component with "_" turned into a space.
    public static func cityName(_ tzID: String) -> String {
        let last = tzID.split(separator: "/").last.map(String.init) ?? tzID
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// The system time zone's city and point, or nil when the tables don't know it (e.g. "UTC").
    public static func current() -> (city: String, point: GeoPoint)? {
        let id = TimeZone.current.identifier
        for file in ["zone1970.tab", "zone.tab"] {
            guard let text = try? String(contentsOfFile: "/usr/share/zoneinfo/" + file, encoding: .utf8),
                  let p = parse(text)[id] else { continue }
            return (cityName(id), p)
        }
        return nil
    }

    /// ±DDMM±DDDMM or ±DDMMSS±DDDMMSS.
    private static func coordinates(_ s: String) -> GeoPoint? {
        let chars = Array(s)
        guard let split = chars.indices.dropFirst().first(where: { chars[$0] == "+" || chars[$0] == "-" }),
              let lat = component(String(chars[..<split]), degDigits: 2),
              let lon = component(String(chars[split...]), degDigits: 3) else { return nil }
        return GeoPoint(lat: lat, lon: lon)
    }

    private static func component(_ s: String, degDigits: Int) -> Double? {
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(s.dropFirst())
        guard digits.count == degDigits + 2 || digits.count == degDigits + 4,
              digits.allSatisfy(\.isNumber) else { return nil }
        let deg = Double(String(digits[..<degDigits]))!
        let min = Double(String(digits[degDigits..<(degDigits + 2)]))!
        let sec = digits.count > degDigits + 2 ? Double(String(digits[(degDigits + 2)...]))! : 0
        let v = deg + min / 60 + sec / 3600
        return sign == "-" ? -v : v
    }
}
