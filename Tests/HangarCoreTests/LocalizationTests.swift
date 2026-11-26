import Foundation
import Testing
@testable import HangarCore

/// One language's compiled strings in HangarCore's resource bundle: lookups that do not depend on the
/// language the tests happen to run in.
func strings(_ language: String) throws -> Bundle {
    let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"), "no \(language).lproj")
    return try #require(Bundle(path: path))
}

/// A HangarCore message in the language its lookups resolve to now, formatted like `String(localized:)` does.
func current(_ key: String, _ arguments: any CVarArg...) throws -> String {
    let language = try #require(Bundle.module.preferredLocalizations.first)
    return String(format: try strings(language).localizedString(forKey: key, value: nil, table: nil), arguments: arguments)
}

@Suite struct LocalizationTests {
    /// Both String Catalogs, read from the source tree.
    static let catalogs = ["HangarCore", "Hangar"].map {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/\($0)/Localizable.xcstrings")
    }

    static func placeholders(_ text: String) -> [String] {
        text.matches(of: /%(\d+\$)?(lld|ld|d|@|f)/).map { String($0.output.0) }
    }

    @Test(arguments: catalogs) func everyKeyHasEnglishAndItalianWithTheSamePlaceholders(_ catalog: URL) throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        #expect(json["sourceLanguage"] as? String == "en")
        let entries = try #require(json["strings"] as? [String: [String: Any]])
        #expect(entries.count > 10)
        for (key, entry) in entries {
            let localizations = entry["localizations"] as? [String: [String: [String: String]]] ?? [:]
            #expect(Set(localizations.keys) == ["en", "it"], "\(key): \(localizations.keys.sorted())")
            for (language, unit) in localizations {
                let value = unit["stringUnit"]?["value"] ?? ""
                #expect(unit["stringUnit"]?["state"] == "translated", "\(language): \(key)")
                #expect(!value.isEmpty, "\(language): \(key)")
                #expect(Self.placeholders(value) == Self.placeholders(key), "\(language): \(key) → \(value)")
            }
        }
    }

    @Test func compiledTablesHaveTheSameKeysInBothLanguages() throws {
        func keys(_ language: String) throws -> Set<String> {
            let file = try #require(try strings(language).url(forResource: "Localizable", withExtension: "strings"))
            return Set(try #require(NSDictionary(contentsOf: file) as? [String: String]).keys)
        }
        let english = try keys("en"), italian = try keys("it")
        #expect(english == italian)
        #expect(english.contains("invalid URL"))
    }

    @Test func coreMessagesResolveInBothLanguages() throws {
        let en = try strings("en"), it = try strings("it")
        func both(_ key: String) -> (String, String) {
            (en.localizedString(forKey: key, value: nil, table: nil), it.localizedString(forKey: key, value: nil, table: nil))
        }
        #expect(both("invalid URL") == ("invalid URL", "URL non valido"))
        #expect(both("Hangar: cannot read the key file") == ("Hangar: cannot read the key file",
                                                             "Hangar: non riesco a leggere il file chiave"))
        let version = both("version %lld is not supported (this app reads version %lld)")
        #expect(String(format: version.0, 5, 4) == "version 5 is not supported (this app reads version 4)")
        #expect(String(format: version.1, 5, 4) == "versione 5 non supportata (questa app legge la 4)")
        let field = both("missing field “%@”%@"), place = both(" in %@")
        #expect(String(format: field.1, "model", String(format: place.1, "presets[1]")) == "manca il campo «model» in presets[1]")
    }

    @Test func theAppFollowsTheLanguageItIsRunIn() throws {
        // what the app does at run time: plain lookups, in whichever of the two languages the system picked
        #expect(["en", "it"].contains(Bundle.module.preferredLocalizations.first))
        #expect(LaunchPlan.keyFileMessage == (try current("Hangar: cannot read the key file")))
        #expect(Tool.droid.spec.serverNote == (try current("It may still ask you to sign in to Factory.")))
    }
}
