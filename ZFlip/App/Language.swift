import Foundation
import SwiftUI

/// The app's own language choice (Settings → Language), applied at once: every localized
/// string, SwiftUI's and `String(localized:)` alike, is looked up in the chosen .lproj.
enum AppLanguage {
    static let key = "appLanguage"
    /// The languages ZApp is translated into ("" = follow the system).
    static let codes = ["en", "fr", "es", "it", "pt-BR", "de", "ru", "uk", "zh-Hans", "ja", "ko", "ar", "th"]

    static var current: String { UserDefaults.standard.string(forKey: key) ?? "" }

    /// Set when the language changes from Settings: the app is rebuilt in the new language and
    /// should land back on Settings, not Home.
    nonisolated(unsafe) private static var reopenSettings = false

    static func reopenSettingsAfterRebuild() { reopenSettings = true }

    static func takeReopenSettings() -> Bool {
        defer { reopenSettings = false }
        return reopenSettings
    }

    /// The flag shown for a language (Assets.xcassets/Flags, flag-icons, MIT).
    static func flag(_ code: String) -> String {
        ["en": "gb", "fr": "fr", "es": "es", "it": "it", "pt-BR": "br", "de": "de", "ru": "ru", "uk": "ua",
         "zh-Hans": "cn", "ja": "jp", "ko": "kr", "ar": "sa", "th": "th"][code] ?? "gb"
    }

    /// "Français", "日本語", "العربية": each language in its own words.
    static func name(_ code: String) -> String {
        Locale(identifier: code).localizedString(forIdentifier: code)?.capitalized(with: Locale(identifier: code)) ?? code
    }

    static func locale(_ code: String) -> Locale { code.isEmpty ? .autoupdatingCurrent : Locale(identifier: code) }

    static func isRightToLeft(_ code: String) -> Bool {
        let lang = code.isEmpty ? (Locale.preferredLanguages.first ?? "en") : code
        return Locale.Language(identifier: lang).characterDirection == .rightToLeft
    }

    /// Points Bundle.main's string lookups at the chosen language (or back to the system's).
    static func apply(_ code: String) {
        UserDefaults.standard.set(code, forKey: key)
        // System prompts (Bluetooth, camera) read this on the next launch.
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        LanguageBundle.override = code.isEmpty ? nil : Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
        if object_getClass(Bundle.main) != LanguageBundle.self {
            object_setClass(Bundle.main, LanguageBundle.self)
        }
    }
}

/// Bundle.main's class while an app language is set: strings come from that .lproj.
private final class LanguageBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var override: Bundle?

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let bundle = Self.override {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}
