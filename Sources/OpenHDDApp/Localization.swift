import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case italian = "it"
    case spanish = "es"

    static let preferenceKey = "CustodriveLanguage"
    // Fixed for this launch: changing language never interrupts an edit session
    // or mixes languages in messages already displayed by the browser model.
    static let current = saved(in: .standard)

    static func saved(in defaults: UserDefaults) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .english
    }

    var id: String { rawValue }
    var name: String {
        switch self {
        case .english: return "English"
        case .italian: return "Italiano"
        case .spanish: return "Español"
        }
    }
    var locale: Locale { Locale(identifier: rawValue) }

    func bundle(in resources: Bundle = .main) -> Bundle? {
        resources.path(forResource: rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}

/// Keeps interpolation values separate from the translation key. File names
/// containing braces or percent signs are inserted verbatim, never interpreted.
struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]

    init(stringLiteral value: String) { key = value; arguments = [] }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }

    func rendered(language: AppLanguage, resources: Bundle = .main) -> String {
        let english = AppLanguage.english.bundle(in: resources)?
            .localizedString(forKey: key, value: key, table: nil) ?? key
        let template = language.bundle(in: resources)?
            .localizedString(forKey: key, value: english, table: nil) ?? english
        guard !arguments.isEmpty else { return template }
        // Split once so placeholders inside a user's file name remain literal.
        let pattern = #/\{([0-9]+)\}/#
        var result = ""
        var cursor = template.startIndex
        for match in template.matches(of: pattern) {
            result += template[cursor..<match.range.lowerBound]
            if let index = Int(match.1), arguments.indices.contains(index) {
                result += arguments[index]
            } else {
                result += template[match.range]
            }
            cursor = match.range.upperBound
        }
        result += template[cursor...]
        return result
    }
}

func L(_ message: LocalizedMessage) -> String {
    message.rendered(language: .current)
}

struct LanguagePicker: View {
    @AppStorage(AppLanguage.preferenceKey) private var selected: AppLanguage = .english

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L("Language"), selection: $selected) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.name).tag(language)
                }
            }
            .pickerStyle(.menu)
            Text(selected == .current ? L("The language takes effect the next time the app starts.") :
                    L("Restart Custodrive to apply the selected language."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
