// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case italian = "it", english = "en", french = "fr"
    var id: String { rawValue }
    var nativeName: String { switch self { case .italian: return "Italiano"; case .english: return "English"; case .french: return "Français" } }
    var locale: Locale { Locale(identifier: rawValue) }
    static let preferenceKey = "app.language"
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "it") ?? .italian }
}

/// Presentation-only translation. Stored profiles, protocol values and identity
/// checks always retain their original values. No network service is involved.
struct AppLocalizer: Sendable {
    struct Template: @unchecked Sendable {
        let source: String
        let expression: NSRegularExpression
        let indices: [Int]
        let literalLength: Int
    }
    // Only these app-owned fragments may be translated inside a template.
    // Profile names, search text, file paths and other parameters remain verbatim.
    private static let translatedArguments: [String: Set<Int>] = [
        "{0}%{1}": [1], "{0} · ⌘{1}": [0],
        "Batteria tastiera, {0}": [0],
        "Passaggio {0}, {1}, attuale": [1], "Passaggio {0}, {1}": [1]
    ]
    let entries: [String: [String: String]]
    let templates: [Template]
    init(entries: [String: [String: String]]) {
        self.entries = entries
        let placeholder = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        self.templates = entries.keys.compactMap { source in
            let matches = placeholder.matches(in: source, range: NSRange(source.startIndex..., in: source))
            guard !matches.isEmpty else { return nil }
            var pattern = "^", cursor = source.startIndex, indices = [Int](), literalLength = 0
            for match in matches {
                guard let range = Range(match.range, in: source), let number = Range(match.range(at: 1), in: source) else { return nil }
                let literal = String(source[cursor..<range.lowerBound]); literalLength += literal.count
                pattern += NSRegularExpression.escapedPattern(for: literal) + "(.*?)"
                indices.append(Int(source[number])!); cursor = range.upperBound
            }
            let literal = String(source[cursor...]); literalLength += literal.count
            pattern += NSRegularExpression.escapedPattern(for: literal) + "$"
            guard literalLength > 0, let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            return Template(source: source, expression: expression, indices: indices, literalLength: literalLength)
        }.sorted { $0.literalLength == $1.literalLength ? $0.source < $1.source : $0.literalLength > $1.literalLength }
    }
    func text(_ source: String, language: AppLanguage, depth: Int = 0) -> String {
        guard language != .italian, depth < 4 else { return source }
        if let exact = entries[source]?[language.rawValue] { return exact }
        for template in templates {
            guard let match = template.expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let translated = entries[template.source]?[language.rawValue] else { continue }
            var values = [Int: String]()
            for (offset, index) in template.indices.enumerated() {
                if let range = Range(match.range(at: offset + 1), in: source) {
                    let value = String(source[range])
                    // Only explicitly app-owned fragments may be translated recursively.
                    values[index] = Self.translatedArguments[template.source]?.contains(index) == true ? text(value, language: language, depth: depth + 1) : value
                }
            }
            // One pass: parameter contents must never be treated as template syntax.
            let tokens = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
            var output = "", cursor = translated.startIndex
            for token in tokens.matches(in: translated, range: NSRange(translated.startIndex..., in: translated)) {
                guard let range = Range(token.range, in: translated), let number = Range(token.range(at: 1), in: translated) else { continue }
                output += translated[cursor..<range.lowerBound]
                output += values[Int(translated[number])!] ?? String(translated[range])
                cursor = range.upperBound
            }
            output += translated[cursor...]
            return output
        }
        // Compound diagnostics may contain independently translated lines.
        if source.contains("\n") { return source.components(separatedBy: "\n").map { text($0, language: language, depth: depth + 1) }.joined(separator: "\n") }
        return source
    }
    /// Explicit parameters avoid ambiguous delimiter parsing in composite labels.
    /// Arguments are already formatted and are always inserted verbatim, once.
    func format(_ source: String, arguments: [String], language: AppLanguage) -> String {
        let template = language == .italian ? source : entries[source]?[language.rawValue] ?? source
        let tokens = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        var output = "", cursor = template.startIndex
        for token in tokens.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let range = Range(token.range, in: template), let number = Range(token.range(at: 1), in: template), let index = Int(template[number]) else { continue }
            output += template[cursor..<range.lowerBound]
            output += arguments.indices.contains(index) ? arguments[index] : String(template[range])
            cursor = range.upperBound
        }
        return output + template[cursor...]
    }
}

enum L10n {
    static let catalog: AppLocalizer = {
        guard let url = Bundle.main.url(forResource: "Localization", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return AppLocalizer(entries: [:]) }
        return AppLocalizer(entries: entries)
    }()
    static func string(_ source: String) -> String { catalog.text(source, language: .current) }
    static func format(_ source: String, _ arguments: [String]) -> String { catalog.format(source, arguments: arguments, language: .current) }
    static func date(_ date: Date, includeDay: Bool = false) -> String {
        date.formatted(Date.FormatStyle(date: includeDay ? .abbreviated : .omitted, time: .shortened).locale(AppLanguage.current.locale))
    }
}
