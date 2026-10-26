import Foundation

let folder = CommandLine.arguments[1]
let definition = KeyboardDefinition.q6ISO
var checks = 0
@MainActor func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
}
func fixture(_ name: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: "\(folder)/\(name).json")) }
@MainActor func expectFailure(_ label: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected failure: \(label)") } catch { checks += 1 }
}

for name in ["official", "reordered", "escaped-numeric", "physical-only", "padded", "missing-version"] {
    let decoded = try LauncherBackup.decode(fixture(name))
    require(decoded.layers == definition.defaultLayers, "\(name): every matrix position must match the source fixture")
    require(decoded.encoders == definition.defaultEncoders, "\(name): encoder left/right mismatch")
}
let noKnob = try LauncherBackup.decode(fixture("missing-knob"))
require(noKnob.encoders == nil, "Absent encoder data must preserve the caller's existing values")
for name in ["bad-hash", "wrong-device", "wrong-version", "bad-encoder", "boolean-encoder", "missing-physical-key", "duplicate-key", "outside-matrix", "nonzero-padding", "out-of-range-keycode", "fractional-keycode", "boolean-id", "duplicate-root", "deep-extra"] {
    expectFailure(name) { _ = try LauncherBackup.decode(fixture(name)) }
}
expectFailure("oversized input") { _ = try LauncherBackup.decode(Data(repeating: 32, count: 2_000_001)) }
expectFailure("incomplete export") { _ = try LauncherBackup.encode(layers: Array(definition.defaultLayers.prefix(3)), encoders: definition.defaultEncoders) }
expectFailure("incomplete encoder export") { _ = try LauncherBackup.encode(layers: definition.defaultLayers, encoders: [[5, 6]]) }
let encoded = try LauncherBackup.encode(layers: definition.defaultLayers, encoders: definition.defaultEncoders)
try encoded.write(to: URL(fileURLWithPath: "\(folder)/native-export.json"))
let decoded = try LauncherBackup.decode(encoded)
require(decoded.layers == definition.defaultLayers, "Round-trip layer mismatch")
require(decoded.encoders == definition.defaultEncoders, "Round-trip encoder mismatch")
print("Launcher backup: \(checks) checks passed; native-export.json ready for independent JavaScript verification.")
