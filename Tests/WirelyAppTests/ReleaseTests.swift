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
}
