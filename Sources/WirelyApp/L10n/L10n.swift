import Foundation
import SwiftUI
import WirelyCore

enum AppLanguage: String, CaseIterable, Identifiable {
    case en, tr
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .en: return "English"
        case .tr: return "Türkçe"
        }
    }
    var locale: Locale {
        switch self {
        case .en: return Locale(identifier: "en_US")
        case .tr: return Locale(identifier: "tr_TR")
        }
    }
}

/// String keys. The en/tr tables live in `Strings_en.swift` / `Strings_tr.swift`.
enum L: String, CaseIterable {
    // Connection state
    case connected, notConnected, connecting, noResponse, noResponseHint, failed
    case connect, disconnect
    // Facts
    case distance, latency, download, upload, you, exitServer
    case serverLocationUnknown, locatingServer, lastHandshake, server, duration, connectedFor
    case agoSeconds, agoMinutes, agoHours, never
    // Import / profiles
    case importProfile, importAction, chooseFile, dropHere, edit, rename, delete, cancel, save, done
    case profiles, importFailed
    // Service
    case installService, installServiceExplain, updateService, serviceUpdateNeeded, update
    case serviceStarting, serviceExplain, serviceNewerApp
    // Settings
    case settings, language, notifications
    case notifyConnectedTitle, notifyDroppedTitle, notifyRestoredTitle, notifyFailedTitle
    // Generic
    case genericError, connectFailed, disconnectFailed
    // Config errors
    case errMissingInterface, errMissingPrivateKey, errNoPeers, errInvalidKey, errInvalidValue
    case errInvalidValueFull, errUnsupportedKey, errUnknownSection, errSyntax
    // Helper client errors
    case errServiceNotRunning, errServiceTimeout, errServiceIO, errServiceBadResponse
    // Helper error codes
    case errResolve, errCommandFailed, errWireguard, errMissingConfig, errInvalidRequest, errAuth
    // Window, menu bar
    case openWirely, settingsEllipsis, quit, noProfilesYet, close, moreInfo, editConfigTitle
    case renameTitle, deleteConfirm
    // Profile details
    case address, dns, routes, allTraffic, mtu, mtuAuto, publicKey, ignoredKeysNote
    // Settings
    case general, service, about, serviceStatus, serviceReady, serviceNotInstalled, serviceChecking
    case serviceOutdatedState, uninstallService, openLog, version, credits
    // Store / installer errors
    case errUnsupportedFile, errZipOpen, errNoConfInZip, errProfileNotFound, errFileIO
    case errInstallCancelled, errInstallMissingFiles, errInstallFailed, errExitCode
}

final class L10n: ObservableObject {
    static let shared = L10n()
    static let defaultsKey = "language"

    @Published var language: AppLanguage {
        didSet {
            guard persist, language != oldValue else { return }
            defaults.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    private let defaults: UserDefaults
    private let persist: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.persist = true
        self.language = defaults.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .en
    }

    /// Fixed-language instance that never touches UserDefaults (legacy v1 views, tests).
    init(fixed language: AppLanguage) {
        self.defaults = .standard
        self.persist = false
        self.language = language
    }

    var locale: Locale { language.locale }

    func table(_ language: AppLanguage) -> [L: String] {
        language == .en ? stringsEN : stringsTR
    }

    func callAsFunction(_ key: L) -> String {
        table(language)[key] ?? stringsEN[key] ?? key.rawValue
    }

    func format(_ key: L, _ args: CVarArg...) -> String {
        String(format: self(key), locale: locale, arguments: args)
    }

    func describe(_ e: ConfigError) -> String {
        switch e {
        case .missingInterfaceSection: return self(.errMissingInterface)
        case .missingPrivateKey: return self(.errMissingPrivateKey)
        case .noPeers: return self(.errNoPeers)
        case .invalidKey(let field): return format(.errInvalidKey, field)
        case .invalidValue(let key, let value): return format(.errInvalidValueFull, key, value)
        case .unsupportedKey(let key): return format(.errUnsupportedKey, key)
        case .unknownSection(let name): return format(.errUnknownSection, name)
        case .syntax(let line): return format(.errSyntax, String(line))
        }
    }

    /// Any error as localised text (config and helper-client errors get their translations).
    func message(for error: Error) -> String {
        if let e = error as? ConfigError { return describe(e) }
        if let e = error as? HelperClientError { return describe(e) }
        return error.localizedDescription
    }

    func describe(_ e: HelperClientError) -> String {
        switch e {
        case .notRunning: return self(.errServiceNotRunning)
        case .timeout: return self(.errServiceTimeout)
        case .io(let msg): return format(.errServiceIO, msg)
        case .badResponse: return self(.errServiceBadResponse)
        }
    }

    func describe(helperErrorCode code: String?, arg: String?, fallback: String?) -> String {
        let a = arg ?? ""
        switch code {
        case "config.missingInterfaceSection": return self(.errMissingInterface)
        case "config.missingPrivateKey": return self(.errMissingPrivateKey)
        case "config.noPeers": return self(.errNoPeers)
        case "config.invalidKey": return format(.errInvalidKey, a)
        case "config.invalidValue": return format(.errInvalidValue, a)
        case "config.unsupportedKey": return format(.errUnsupportedKey, a)
        case "config.unknownSection": return format(.errUnknownSection, a)
        case "config.syntax": return format(.errSyntax, a)
        case "resolve": return format(.errResolve, a)
        case "commandFailed": return format(.errCommandFailed, a)
        case "wireguard": return format(.errWireguard, a)
        case "request.missingConfig": return self(.errMissingConfig)
        case "request.invalid": return self(.errInvalidRequest)
        case "auth": return self(.errAuth)
        default: return fallback ?? self(.genericError)
        }
    }
}
