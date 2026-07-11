import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case turkish = "tr"
    case english = "en"
    case spanish = "es"

    var id: String { rawValue }

    var locale: Locale { Locale(identifier: rawValue) }

    var labelKey: String {
        switch self {
        case .turkish: "lang_tr"
        case .english: "lang_en"
        case .spanish: "lang_es"
        }
    }

    /// Native name so the menu is readable regardless of current UI language.
    var nativeName: String {
        switch self {
        case .turkish: "Türkçe"
        case .english: "English"
        case .spanish: "Español"
        }
    }
}

enum L10n {
    static var currentCode: String {
        UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.turkish.rawValue
    }

    static var currentLocale: Locale {
        Locale(identifier: currentCode)
    }

    static func string(_ key: String, locale: Locale? = nil) -> String {
        let languageCode: String
        if let locale {
            if let code = locale.language.languageCode?.identifier {
                languageCode = code
            } else {
                languageCode = String(locale.identifier.prefix(while: { $0 != "_" && $0 != "-" }))
            }
        } else {
            languageCode = currentCode
        }

        if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: key, table: "Localizable")
        }

        return Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func string(_ key: String, _ args: CVarArg..., locale: Locale? = nil) -> String {
        let format = string(key, locale: locale)
        return String(format: format, locale: locale ?? currentLocale, arguments: args)
    }
}
