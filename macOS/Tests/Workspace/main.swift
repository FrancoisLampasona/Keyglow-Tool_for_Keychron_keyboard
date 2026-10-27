import Foundation

// Document-only tests. No app instance, UserDefaults, keyboard enumeration or HID access.
struct TestFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}
func rejects(_ label: String, _ edit: (inout KeyboardWorkspace) -> Void) throws {
    var document = KeyboardWorkspace()
    edit(&document)
    do { try document.validate() }
    catch { return }
    throw TestFailure(description: "Accepted invalid imported profile: \(label)")
}

do {
    let definition = KeyboardDefinition.q6ISO
    try require(definition.keys.count == 110, "Q6 Max ISO must have 109 keys and encoder press")
    try require(Set(definition.keys.map(\.matrixIndex)).count == 110, "Physical positions must be unique")
    try require(Set(definition.keys.compactMap(\.ledIndex)) == Set(0..<109), "All 109 LEDs must map exactly once")
    try require(definition.keys.allSatisfy { (0..<120).contains($0.matrixIndex) }, "Physical matrix bounds")
    try require(definition.key(row:2,col:13)?.secondary != nil, "ISO Enter must keep its L-shaped extension")
    try require(definition.key(row:4,col:1)?.legend == "<", "Italian ISO extra key")
    try require(definition.key(row:3,col:10)?.legend == "ò", "Italian legends")

    var original = KeyboardWorkspace()
    original.layers[2][61] = 0x0104
    original.lighting.perKey["0,0"] = "000000"
    original.lighting.perKeyMode = 4
    original.lighting.indicatorsDisabled = 31
    var region = MixLayerDraft()
    region.keys = ["0,0"]
    region.sequence = [MixEffectDraft(effect:0,hex:"000000",speed:0,durationMilliseconds:0),
                       MixEffectDraft(effect:22,hex:"57D9C1",speed:255,durationMilliseconds:3_600_000)]
    original.lighting.mix = [region]
    original.macros[0].actions = [.init(kind:.down,keycode:224), .init(kind:.tap,keycode:4), .init(kind:.up,keycode:224), .init(kind:.delay,milliseconds:65535)]
    original.macros[1].rawBytes = [1,255,0,7,0] // Opaque data must survive export, never silently re-encode.
    try original.validate()
    let encoded = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(KeyboardWorkspace.self,from:encoded)
    try restored.validate()
    try require(restored == original, "Export/import must preserve every field, opaque macro bytes and IDs")

    // Schema-1 files without collection metadata still import unchanged.
    var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String:Any]
    legacy.removeValue(forKey:"recoveryReason"); legacy.removeValue(forKey:"deletedAt")
    legacy["name"] = "Q6 · prima della lettura"
    let migrated = try JSONDecoder().decode(KeyboardWorkspace.self,from:JSONSerialization.data(withJSONObject:legacy))
    try require(migrated.isRecoveryCopy && migrated.deletedAt == nil, "Legacy automatic copies belong in Recovery")
    var personal = migrated; personal.recoveryReason=""
    try require(!personal.isRecoveryCopy, "Explicit personal metadata overrides a legacy-looking name")
    var trashed = original; trashed.deletedAt=Date(timeIntervalSince1970:12345); trashed.recoveryReason=" · recupero"
    let persistedTrash = try JSONDecoder().decode(KeyboardWorkspace.self,from:JSONEncoder().encode(trashed))
    try require(persistedTrash == trashed && persistedTrash.isRecoveryCopy, "Trash survives relaunch with all RGB, macro and layout data")
    var recovered = persistedTrash; recovered.deletedAt=nil
    try require(recovered.layers == original.layers && recovered.lighting == original.lighting && recovered.macros == original.macros, "Restoring a profile loses no keyboard configuration")

    try rejects("wrong model") { $0.model = "keychron/q6_max/ansi_encoder" }
    try rejects("truncated layer") { $0.layers[0].removeLast() }
    try rejects("truncated encoder") { $0.encoders[0] = [] }
    try rejects("macro slot order") { $0.macros.swapAt(0,1) }
    try rejects("macro slot gap") { $0.macros.removeFirst() }
    try rejects("duplicate macro slots") { $0.macros[1].id = 0 }
    try rejects("macro delay overflow") { $0.macros[0].actions = [.init(kind:.delay,milliseconds:65536)] }
    try rejects("macro extended keycode") { $0.macros[0].actions = [.init(kind:.tap,keycode:0x0104)] }
    try rejects("negative mode, would trap UInt8 conversion") { $0.lighting.perKeyMode = -1 }
    try rejects("mode above firmware range") { $0.lighting.perKeyMode = 5 }
    try rejects("indicator mask overflow") { $0.lighting.indicatorsDisabled = 256 }
    try rejects("invalid indicator color") { $0.lighting.indicatorHex = "red" }
    try rejects("unknown physical key") { $0.lighting.perKey["9,99"] = "FFFFFF" }
    try rejects("invalid per-key color") { $0.lighting.perKey["0,0"] = "FFFFFG" }
    try rejects("nonfinite hue") { $0.lighting.hue = .nan }
    try rejects("brightness overflow") { $0.lighting.brightness = 101 }
    try rejects("negative backlight timeout") { $0.advanced.backlightSeconds = -1 }
    try rejects("sleep seconds overflow") { $0.advanced.sleepMinutes = 1093 }
    try rejects("invalid mix step") {
        var mix = MixLayerDraft()
        mix.sequence = [.init(effect:255,hex:"FFFFFF",speed:128,durationMilliseconds:1000)]
        $0.lighting.mix = [mix]
    }
    try rejects("mix duration overflow") {
        var mix = MixLayerDraft()
        mix.sequence = [.init(effect:1,hex:"FFFFFF",speed:128,durationMilliseconds:Int.max)]
        $0.lighting.mix = [mix]
    }
    try rejects("oversized sequence") {
        var mix = MixLayerDraft()
        mix.sequence = Array(repeating:MixEffectDraft(),count:65)
        $0.lighting.mix = [mix]
    }
    print("Workspace: ISO matrix/LED mapping, lossless JSON roundtrip, opaque macro preservation and malformed profile guards passed. No hardware or preferences access.")
} catch {
    fputs("Workspace test failure: \(error)\n", stderr)
    exit(1)
}
