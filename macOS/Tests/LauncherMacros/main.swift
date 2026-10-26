import Foundation

let folder = CommandLine.arguments[1]
var checks = 0
@MainActor func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
}
func fixture(_ name: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: "\(folder)/\(name).json")) }
@MainActor func failure(_ name: String, contains: String? = nil, _ work: () throws -> Void) {
    do { try work(); fatalError("Expected rejection: \(name)") }
    catch {
        if let contains { require(error.localizedDescription.contains(contains), "\(name): unexpected error \(error)") }
        checks += 1
    }
}
let decoded = try LauncherMacroBackup.decode(fixture("current"))
require(decoded.count == 3 && decoded.map(\.id) == [0, 1, 2], "Slot indices preserved")
require(decoded.map(\.name) == ["Test è 🔊", "Vuota", "e\u{301}"], "Unicode names preserved")
require(decoded[1].actions.isEmpty, "Empty middle slot preserved")
require(decoded[0].actions.map(\.kind) == [.down, .tap, .delay, .up, .text], "Event order and types preserved")
require(decoded[0].actions[0].keycode == 227 && decoded[0].actions[1].keycode == 4 && decoded[2].actions[0].keycode == 50, "Source enum keycodes preserved")
require(decoded[0].actions[2].milliseconds == 125, "Delay preserved")
require(decoded[0].actions[4].text == "hello /\"\\\u{8}\u{c}\n\r\t\u{2}\u{1f}\u{7f}", "ASCII controls preserved")
let normalized = try LauncherMacroBackup.decode(fixture("numeric-escaped"))
require(normalized == decoded, "JS numeric and Unicode-escape normalization must match MD5")
let renamed = try LauncherMacroBackup.decode(fixture("changed-names"))
require(renamed[0].name == "Renamed", "Names are outside Launcher digest")
let everyKey = try LauncherMacroBackup.decode(fixture("all-keys"))
let expectedCodes = try JSONDecoder().decode([UInt16].self, from: fixture("all-key-values"))
require(everyKey[0].actions.map(\.keycode) == expectedCodes && expectedCodes.count == 194, "All source enum mappings, including alias, must match")
let mic = try LauncherMacroBackup.decode(fixture("current-mic"))
require(mic[0].actions[0].keycode == 193, "Modern KC_MIC mapping")
let bounds = try LauncherMacroBackup.decode(fixture("boundary-delays"))
require(bounds[0].actions[0].milliseconds == 0 && bounds[0].actions[1].milliseconds == 65535, "Delay boundaries")

for name in ["bad-hash", "other-device", "missing-names", "extra-metadata", "mouse-down", "mouse-up", "mouse-key", "unknown-command", "unknown-symbol", "numeric-symbol", "extra-event-data", "boolean-type", "fractional-type", "negative-delay", "oversized-delay", "fractional-delay", "boolean-delay", "string-delay", "unicode-text", "zero-text", "one-text", "empty-set", "too-many-slots", "too-many-actions", "non-array-slot", "non-array-event"] {
    failure(name) { _ = try LauncherMacroBackup.decode(fixture(name)) }
}
failure("legacy requires explicit method", contains: "legacy") { _ = try LauncherMacroBackup.decode(fixture("legacy")) }
let legacy = try LauncherMacroBackup.decodeLegacy(fixture("legacy"))
require(legacy.map(\.actions) == decoded.map(\.actions), "Legacy event sequence preserved")
require(legacy.map(\.name) == ["Macro 1", "Macro 2", "Macro 3"], "Legacy files have no names")
for name in ["legacy-mic", "legacy-lpad"] { failure(name, contains: "ambiguità") { _ = try LauncherMacroBackup.decodeLegacy(fixture(name)) } }
failure("oversize") { _ = try LauncherMacroBackup.decode(Data(repeating: 32, count: 2_000_001)) }
failure("opaque buffer", contains: "buffer originale") { _ = try LauncherMacroBackup.encode(macros: [MacroDraft(id: 0, name: "Raw", rawBytes: [1, 99, 0])]) }
failure("empty opaque buffer marker") { _ = try LauncherMacroBackup.encode(macros: [MacroDraft(id: 0, name: "Raw", rawBytes: [])]) }
failure("nonordinal IDs") { _ = try LauncherMacroBackup.encode(macros: [MacroDraft(id: 4, name: "M4")]) }
failure("unmapped export keycode") { _ = try LauncherMacroBackup.encode(macros: [MacroDraft(id: 0, name: "M0", actions: [.init(kind: .tap, keycode: 0x1234)])]) }
failure("mouse export keycode") { _ = try LauncherMacroBackup.encode(macros: [MacroDraft(id: 0, name: "M0", actions: [.init(kind: .tap, keycode: 209)])]) }
failure("Unicode export text", contains: "ASCII") { _ = try LauncherMacroBackup.encode(macros: [MacroDraft(id: 0, name: "M0", actions: [.init(kind: .text, text: "é")])]) }
failure("invalid export delay") { _ = try LauncherMacroBackup.encode(macros: [MacroDraft(id: 0, name: "M0", actions: [.init(kind: .delay, milliseconds: -1)])]) }
let data = try LauncherMacroBackup.encode(macros: decoded)
try data.write(to: URL(fileURLWithPath: "\(folder)/native-export.json"))
let roundTrip = try LauncherMacroBackup.decode(data)
require(roundTrip == decoded, "Supported actions and names round trip")
try LauncherMacroBackup.encode(macros: everyKey).write(to: URL(fileURLWithPath: "\(folder)/native-all-keys.json"))
print("Launcher macros: \(checks) checks passed.")
