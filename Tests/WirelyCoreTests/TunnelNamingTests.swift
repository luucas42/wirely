import Testing
@testable import WirelyCore

@Test func sanitizeStripsAndTruncates() {
    #expect(TunnelNaming.sanitize("wg0 (Türkiye)!.conf") == "wg0 Turkiye")
    #expect(TunnelNaming.sanitize("ışık İstanbul") == "isik Istanbul")
    #expect(TunnelNaming.sanitize(String(repeating: "a", count: 40)).count == 32)
    #expect(TunnelNaming.sanitize("!!!") == "tunnel")
}

@Test func uniqueAppendsNumber() {
    #expect(TunnelNaming.unique("india", existing: ["india", "india 2"]) == "india 3")
    #expect(TunnelNaming.unique("India", existing: ["india"]) == "India 2")
    #expect(TunnelNaming.unique("fresh", existing: ["india"]) == "fresh")
}
