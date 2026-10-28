import Testing
@testable import WirelyApp

struct LandMaskTests {
    @Test func landMaskSpotChecks() {
        #expect(LandMask.isLand(lat: 50.11, lon: 8.68))    // Frankfurt
        #expect(LandMask.isLand(lat: 39.93, lon: 32.85))   // Ankara
        #expect(LandMask.isLand(lat: 19.07, lon: 72.88))   // Mumbai
        #expect(!LandMask.isLand(lat: 40, lon: -30))       // Atlantic
        #expect(!LandMask.isLand(lat: 43.2, lon: 34.0))    // Black Sea
        #expect(!LandMask.isLand(lat: 0, lon: -140))       // Pacific
    }
}
