import Testing
import Foundation
@testable import WirelyApp

struct ReleaseTests {
    private let notes = """
    ## What's new

    ### Kill switch
    If the tunnel drops, Wirely blocks all internet traffic until you press **Reconnect**.
    Nothing slips out over your normal connection.

    - On by default: **Settings → General → Kill switch**.
    - With notifications on, you're told the moment it starts blocking.

    <p align="center">
      <img src="https://example.com/blocked-dark.png" width="560" alt="Blocked">
    </p>

    ## Updating from 1.0.0
    1. Quit Wirely (menu bar icon → **Quit**).
    2. Download **Wirely-1.1.0.dmg** below and choose **Replace**.

    **SHA-256** `Wirely-1.1.0.dmg`
    ```
    0000000000000000000000000000000000000000000000000000000000000000
    ```

    <details>
    <summary><b>Türkçe</b></summary>

    ### Yenilikler
    - **Kill switch:** Tünel düşerse Wirely tüm interneti engeller.

    ### 1.0.0'dan güncelleme
    1. Wirely'den çık.
    2. **Wirely-1.1.0.dmg**'yi indir ve **Değiştir**'i seç.

    </details>
    """

    private let releaseJSON = """
    {
      "tag_name": "v1.2.0",
      "name": "Wirely 1.2.0",
      "body": "## Hello\\r\\n- one",
      "html_url": "https://github.com/example/wirely/releases/tag/v1.2.0",
      "draft": false,
      "published_at": "2026-11-02T10:00:00Z",
      "assets": [
        { "name": "Wirely-1.2.0.zip", "browser_download_url": "https://example.com/Wirely-1.2.0.zip" },
        { "name": "Wirely-1.2.0.dmg", "browser_download_url": "https://example.com/Wirely-1.2.0.dmg" }
      ]
    }
    """

    @Test func versionParsingAndOrder() {
        #expect(AppVersion("v1.1.0") == AppVersion("1.1"))
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!)
        #expect(AppVersion("1.2.0")! > AppVersion("v1.1.0")!)
        #expect(AppVersion("abc") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("1.2.3.4") == nil)
    }

    @Test func parsesGitHubRelease() throws {
        let r = try #require(ReleaseInfo.parse(Data(releaseJSON.utf8)))
        #expect(r.version == AppVersion("1.2.0"))
        #expect(r.tag == "v1.2.0")
        #expect(r.name == "Wirely 1.2.0")
        #expect(r.notes == "## Hello\r\n- one")
        #expect(r.pageURL == URL(string: "https://github.com/example/wirely/releases/tag/v1.2.0"))
        #expect(r.dmgURL == URL(string: "https://example.com/Wirely-1.2.0.dmg"))
        #expect(r.publishedAt == Date(timeIntervalSince1970: 1_793_613_600))
    }

    @Test func draftOrMissingTagIsRejected() {
        let draft = releaseJSON.replacingOccurrences(of: "\"draft\": false", with: "\"draft\": true")
        #expect(ReleaseInfo.parse(Data(draft.utf8)) == nil)
        let noTag = releaseJSON.replacingOccurrences(of: "\"tag_name\": \"v1.2.0\",", with: "")
        #expect(ReleaseInfo.parse(Data(noTag.utf8)) == nil)
        #expect(ReleaseInfo.parse(Data("nope".utf8)) == nil)
    }

    @Test func englishNotesStopAtDetails() {
        #expect(ReleaseNotes.blocks(notes, language: .en) == [
            .heading(level: 2, text: "What's new"),
            .heading(level: 3, text: "Kill switch"),
            .paragraph("If the tunnel drops, Wirely blocks all internet traffic until you press **Reconnect**. Nothing slips out over your normal connection."),
            .bullet("On by default: **Settings → General → Kill switch**."),
            .bullet("With notifications on, you're told the moment it starts blocking."),
            .heading(level: 2, text: "Updating from 1.0.0"),
            .numbered(1, "Quit Wirely (menu bar icon → **Quit**)."),
            .numbered(2, "Download **Wirely-1.1.0.dmg** below and choose **Replace**."),
            .paragraph("**SHA-256** `Wirely-1.1.0.dmg`"),
            .code("0000000000000000000000000000000000000000000000000000000000000000"),
        ])
    }

    @Test func turkishNotesUseDetailsBlock() {
        #expect(ReleaseNotes.blocks(notes, language: .tr) == [
            .heading(level: 3, text: "Yenilikler"),
            .bullet("**Kill switch:** Tünel düşerse Wirely tüm interneti engeller."),
            .heading(level: 3, text: "1.0.0'dan güncelleme"),
            .numbered(1, "Wirely'den çık."),
            .numbered(2, "**Wirely-1.1.0.dmg**'yi indir ve **Değiştir**'i seç."),
        ])
    }

    @Test func turkishFallsBackToEnglishWithoutDetails() {
        #expect(ReleaseNotes.blocks("## Hi\r\n- one", language: .tr) == [
            .heading(level: 2, text: "Hi"),
            .bullet("one"),
        ])
    }

    @Test func htmlLinesAreDropped() {
        let md = "<p align=\"center\">\n  <img src=\"x.png\">\n</p>\n> [!NOTE]\n> Careful here.\nAfter."
        #expect(ReleaseNotes.blocks(md, language: .en) == [.paragraph("Careful here. After.")])
    }

    // MARK: Checksum

    private static let hashA = String(repeating: "ab", count: 32)
    private static let hashB = String(repeating: "cd", count: 32)

    private func json(digest: String?, body: String) -> Data {
        let digestField = digest.map { ", \"digest\": \"\($0)\"" } ?? ""
        return Data("""
        {"tag_name":"v9.9.9","name":"Wirely 9.9.9","body":\(String(decoding: try! JSONEncoder().encode(body), as: UTF8.self)),
         "html_url":"https://github.com/example/app/releases/tag/v9.9.9","draft":false,
         "assets":[{"name":"Wirely-9.9.9.dmg","size":5590491\(digestField),
         "browser_download_url":"https://github.com/example/app/releases/download/v9.9.9/Wirely-9.9.9.dmg"}]}
        """.utf8)
    }

    private let notesWithHash = "Notes\n\n**SHA-256** `Wirely-9.9.9.dmg`\n```\n\(String(repeating: "cd", count: 32))\n```\n"

    @Test func digestIsParsedFromAsset() throws {
        let r = try #require(ReleaseInfo.parse(json(digest: "sha256:\(Self.hashA)", body: "x")))
        #expect(r.dmgSHA256 == Self.hashA)
    }

    @Test func uppercaseDigestIsLowercased() throws {
        let r = try #require(ReleaseInfo.parse(json(digest: "sha256:\(Self.hashA.uppercased())", body: "x")))
        #expect(r.dmgSHA256 == Self.hashA)
    }

    @Test func malformedDigestFallsBackToNotes() throws {
        for bad in ["sha256:xyz", "sha256:\(String(Self.hashA.dropLast()))", "md5:\(Self.hashA)"] {
            let r = try #require(ReleaseInfo.parse(json(digest: bad, body: notesWithHash)))
            #expect(r.dmgSHA256 == Self.hashB, "digest \(bad)")
        }
    }

    @Test func notesOnlyHashIsParsed() throws {
        let r = try #require(ReleaseInfo.parse(json(digest: nil, body: notesWithHash)))
        #expect(r.dmgSHA256 == Self.hashB)
        let upper = notesWithHash.replacingOccurrences(of: Self.hashB, with: Self.hashB.uppercased())
        #expect(try #require(ReleaseInfo.parse(json(digest: nil, body: upper))).dmgSHA256 == Self.hashB)
    }

    @Test func noUsableChecksumIsNil() throws {
        #expect(try #require(ReleaseInfo.parse(json(digest: nil, body: "No hash here"))).dmgSHA256 == nil)
        // Hash before the marker, or not a whole 64-hex token, doesn't count.
        let before = "\(Self.hashA)\n**SHA-256** soon"
        #expect(try #require(ReleaseInfo.parse(json(digest: nil, body: before))).dmgSHA256 == nil)
        let long = "**SHA-256**\n\(Self.hashA)ab"
        #expect(try #require(ReleaseInfo.parse(json(digest: nil, body: long))).dmgSHA256 == nil)
    }

    @Test func oldCachedReleaseWithoutChecksumDecodes() throws {
        let old = """
        {"version":{"parts":[1,2,0]},"tag":"v1.2.0","name":"Wirely 1.2.0","notes":"n",
         "pageURL":"https://example.com/r","dmgURL":"https://example.com/a.dmg"}
        """
        let r = try JSONDecoder().decode(ReleaseInfo.self, from: Data(old.utf8))
        #expect(r.dmgSHA256 == nil)
        #expect(r.dmgURL == URL(string: "https://example.com/a.dmg"))
    }
}
