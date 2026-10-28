import Foundation

@main
struct LocalizationTest {
    static func main() {
        guard CommandLine.arguments.count == 2,
              let resources = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("Usage: localization-test APP_BUNDLE")
        }
        var keys: Set<String>?
        let placeholders = #/\{([0-9]+)\}/#
        for language in AppLanguage.allCases {
            guard let bundle = language.bundle(in: resources),
                  let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
                  let data = try? Data(contentsOf: url),
                  let catalog = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            else { fatalError("Missing catalog: \(language)") }
            let currentKeys = Set(catalog.keys)
            if let keys { precondition(keys == currentKeys, "Catalog key mismatch") }
            keys = currentKeys
            for (key, value) in catalog {
                precondition(!value.isEmpty)
                precondition(key.matches(of: placeholders).map { String($0.1) }.sorted() ==
                    value.matches(of: placeholders).map { String($0.1) }.sorted(), key)
                precondition(LocalizedMessage(stringLiteral: key).rendered(language: language, resources: resources) == value)
            }
            let fileName = "private-{1}-100%.txt"
            let name: LocalizedMessage = "New Folder \(fileName)"
            let prefix = [AppLanguage.english: "New Folder", .italian: "Nuova cartella", .spanish: "Nueva carpeta"][language]!
            precondition(name.rendered(language: language, resources: resources) == prefix + " " + fileName)
            let unknown: LocalizedMessage = "Uncatalogued \(fileName)"
            precondition(unknown.rendered(language: language, resources: resources) == "Uncatalogued " + fileName)
            let reordered: LocalizedMessage = "Copy \("photo.jpg") to “\("Disk")” \("in root")?"
            precondition(reordered.rendered(language: language, resources: resources).contains("photo.jpg"))
            print("PASS \(language.rawValue): \(catalog.count) translations, placeholders, literal file names, English fallback")
        }
        let defaults = UserDefaults(suiteName: "app.custodrive.localization-tests")!
        for value in ["", "invalid", "en", "it", "es"] {
            defaults.setVolatileDomain([AppLanguage.preferenceKey: value], forName: UserDefaults.argumentDomain)
            precondition(AppLanguage.saved(in: defaults) == (AppLanguage(rawValue: value) ?? .english))
        }
        print("PASS language preference: English default, all supported choices, invalid-value fallback")
    }
}
