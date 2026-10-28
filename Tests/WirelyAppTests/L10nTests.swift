import Testing
import Foundation
import WirelyCore
@testable import WirelyApp

struct L10nTests {
    private func fresh(_ lang: AppLanguage = .en) -> L10n {
        let d = UserDefaults(suiteName: "l10n-test-\(UUID().uuidString)")!
        let l = L10n(defaults: d)
        l.language = lang
        return l
    }

    @Test func everyKeyTranslated() {
        var same = 0
        for k in L.allCases {
            let en = stringsEN[k], tr = stringsTR[k]
            #expect(en?.isEmpty == false, "missing en: \(k)")
            #expect(tr?.isEmpty == false, "missing tr: \(k)")
            if en == tr { same += 1 }
        }
        #expect(Double(same) / Double(L.allCases.count) <= 0.10)
    }

    @Test func switchingLanguageChangesOutput() {
        let l = fresh(.en)
        #expect(l(.connected) == "Connected")
        l.language = .tr
        #expect(l(.connected) == "Bağlı")
        #expect(l.format(.exitServer, "Frankfurt") == "Çıkış Frankfurt")
    }

    @Test func languagePersists() {
        let d = UserDefaults(suiteName: "l10n-persist-\(UUID().uuidString)")!
        #expect(L10n(defaults: d).language == .en)
        L10n(defaults: d).language = .tr
        #expect(L10n(defaults: d).language == .tr)
    }

    @Test func configErrorLocalized() {
        let l = fresh(.tr)
        #expect(l.describe(ConfigError.unsupportedKey("Jc")).contains("Jc"))
        #expect(fresh(.en).describe(ConfigError.syntax(line: 7)).contains("7"))
    }

    @Test func helperClientErrorLocalized() {
        #expect(fresh(.en).describe(HelperClientError.notRunning) == "The Wirely service is not running")
    }

    @Test func helperCodeKnownAndFallback() {
        let l = fresh(.en)
        #expect(l.describe(helperErrorCode: "resolve", arg: "vpn.example.com", fallback: nil).contains("vpn.example.com"))
        #expect(l.describe(helperErrorCode: "config.unsupportedKey", arg: "Jc", fallback: nil).contains("Jc"))
        #expect(l.describe(helperErrorCode: "nope", arg: nil, fallback: "helper text") == "helper text")
        #expect(l.describe(helperErrorCode: nil, arg: nil, fallback: nil) == "Something went wrong")
        #expect(fresh(.tr).describe(helperErrorCode: nil, arg: nil, fallback: nil) == "Bir şeyler ters gitti")
    }

    @Test func helperCodeFallback() {
        #expect(fresh().describe(helperErrorCode: "future.code", arg: nil, fallback: "raw") == "raw")
    }
}
