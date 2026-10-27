// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main struct LocalizationTests {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let entries = try JSONDecoder().decode([String:[String:String]].self, from: data)
        let catalog = AppLocalizer(entries: entries)
        let token = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func tokens(_ value: String) -> [String] {
            token.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { String(value[Range($0.range, in: value)!]) }.sorted()
        }
        precondition(entries.count > 1100)
        for (source, values) in entries {
            precondition(Set(values.keys) == ["en", "fr"], source)
            for language in [AppLanguage.english, .french] {
                let translation = values[language.rawValue]!
                precondition(!translation.isEmpty && tokens(source) == tokens(translation), source)
                precondition(!translation.contains("\\n"), "Literal escaped newline: \(source)")
                precondition(catalog.text(source, language: language) == translation, source)
            }
            precondition(catalog.text(source, language: .italian) == source)
        }
        precondition(catalog.text("Illuminazione", language: .english) == "Lighting")
        precondition(catalog.text("Illuminazione", language: .french) == "Éclairage")
        precondition(catalog.text("12 tasti selezionati", language: .english) == "12 keys selected")
        precondition(catalog.text("12 tasti selezionati", language: .french) == "12 touches sélectionnées")
        precondition(catalog.text("94% · precedente", language: .french) == "94% · précédent")
        precondition(catalog.text("Profili · ⌘5", language: .english) == "Profiles · ⌘5")
        precondition(catalog.text("Profilo esportato: /tmp/été {1} 🟣.json", language: .french) == "Profil exporté : /tmp/été {1} 🟣.json")
        precondition(catalog.text("Modello sconosciuto 🟣", language: .english) == "Modello sconosciuto 🟣")
        precondition(catalog.text("94%", language: .english) == "94%")
        precondition(catalog.text("Illuminazione\nProfili", language: .french) == "Éclairage\nProfils")
        precondition(catalog.text("Sposta nel cestino Colore", language: .french) == "Placer Colore dans la corbeille")
        precondition(catalog.text("Modifica Colore", language: .english) == "Edit Colore")
        precondition(catalog.text("Passaggio 1, Backup, attuale", language: .french) == "Étape 1, Sauvegarde, actuelle")
        precondition(catalog.text("Passaggio 2, Riepilogo", language: .english) == "Step 2, Summary")
        precondition(catalog.format("{0} · {1} · riga {2}, colonna {3}", arguments: ["Knob · press", "Mute", "0", "13"], language: .english) == "Knob · press · Mute · row 0, column 13")
        precondition(catalog.text("Batteria tastiera, Batteria —", language: .english) == "Keyboard battery, Battery —")
        let preference = AppLanguage.preferenceKey
        let previous = UserDefaults.standard.object(forKey: preference)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: preference) } else { UserDefaults.standard.removeObject(forKey: preference) } }
        UserDefaults.standard.removeObject(forKey: preference)
        precondition(AppLanguage.current == .italian)
        for language in AppLanguage.allCases {
            UserDefaults.standard.set(language.rawValue, forKey: preference)
            precondition(AppLanguage.current == language)
        }
        UserDefaults.standard.set("unknown", forKey: preference)
        precondition(AppLanguage.current == .italian)
        print("Localization: \(entries.count) entries, EN/FR parity, templates, Unicode parameters, multiline fallback and persistent language passed")
    }
}
