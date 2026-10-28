import SwiftUI
import AppKit
import CoreText

enum AppFonts {
    private static let wghtTag = 0x77676874   // 'wght'
    private nonisolated(unsafe) static var registered = false

    static func register() {
        guard let url = Bundle.main.url(forResource: "Manrope-Variable", withExtension: "ttf", subdirectory: "Fonts")
        else { return }
        var err: Unmanaged<CFError>?
        registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [Int: Font] = [:]

    /// Manrope at a variable weight (400...800); system font if Manrope isn't registered.
    /// Cached: views ask for the same few sizes on every render and building an NSFont isn't free.
    static func manrope(_ size: CGFloat, weight: CGFloat) -> Font {
        let key = Int((size * 10).rounded()) * 10_000 + Int(weight.rounded())
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let font = cache[key] { return font }
        let font = makeManrope(size, weight: weight)
        // Only cache once registration is settled, so an early miss doesn't pin the system fallback.
        if registered { cache[key] = font }
        return font
    }

    private static func makeManrope(_ size: CGFloat, weight: CGFloat) -> Font {
        let base = NSFontDescriptor(fontAttributes: [.family: "Manrope"])
        let desc = base.addingAttributes([
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtTag: weight]
        ])
        if let f = NSFont(descriptor: desc, size: size), f.familyName == "Manrope" {
            return Font(f)
        }
        return .system(size: size, weight: systemWeight(weight))
    }

    private static func systemWeight(_ w: CGFloat) -> Font.Weight {
        switch w {
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        default: return .heavy
        }
    }
}
