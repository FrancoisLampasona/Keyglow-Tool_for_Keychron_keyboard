import Foundation

// Document-only tests. No app instance, UserDefaults, keyboard enumeration or HID access.
struct TestFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}
extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw TestFailure(description: message) }
        return self
    }
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

    // Profile library rules. Values only: no preferences, dialogs or files.
    func profile(_ name: String, at seconds: TimeInterval, recovery: String = "", deleted: Bool = false, edit: (inout KeyboardWorkspace) -> Void = { _ in }) -> KeyboardWorkspace {
        var item = KeyboardWorkspace(); item.name = name; item.updatedAt = Date(timeIntervalSince1970: seconds)
        item.recoveryReason = recovery; item.deletedAt = deleted ? Date(timeIntervalSince1970: seconds) : nil
        edit(&item); return item
    }
    var draft = KeyboardWorkspace()
    try require(!ProfileLibrary.needsRecoveryCopy(of: draft, in: []), "Untouched factory values need no recovery copy")
    draft.layers[0][5] = 0x0004
    try require(ProfileLibrary.needsRecoveryCopy(of: draft, in: []), "An edited draft with no saved profile is preserved")
    var savedCopy = draft; savedCopy.id = UUID(); savedCopy.updatedAt = Date(timeIntervalSince1970: 50); savedCopy.origin = "Altro"
    try require(savedCopy.sameConfiguration(as: draft) && savedCopy != draft, "Identity, date and origin are not configuration")
    try require(!ProfileLibrary.needsRecoveryCopy(of: draft, in: [savedCopy]), "A draft equal to the saved or loaded profile is not copied again")
    var recoveryTwin = savedCopy; recoveryTwin.recoveryReason = " · recupero"
    try require(!ProfileLibrary.needsRecoveryCopy(of: draft, in: [recoveryTwin]), "An identical recovery copy is not duplicated")
    var trashedTwin = savedCopy; trashedTwin.deletedAt = Date()
    try require(ProfileLibrary.needsRecoveryCopy(of: draft, in: [trashedTwin]), "A copy in the trash does not protect the draft")
    for edit: (inout KeyboardWorkspace) -> Void in [{ $0.name = "Altro nome" }, { $0.encoders[1][0] = 7 }, { $0.macros[2].actions = [.init(kind:.tap,keycode:4)] }, { $0.lighting.speed = 9 }, { $0.advanced.sleepMinutes = 30 }] {
        var changed = draft; edit(&changed)
        try require(ProfileLibrary.needsRecoveryCopy(of: changed, in: [savedCopy]), "Any configuration difference from the saved profile is preserved")
    }

    var library = [KeyboardWorkspace]()
    for index in 0..<25 { library.append(profile("R\(index)", at: Double(index), recovery: " · recupero")) }
    let personalOld = profile("Personale vecchio", at: -100), trashedRecovery = profile("Cestinata", at: -200, recovery: " · recupero", deleted: true)
    let legacyRecovery: KeyboardWorkspace = { var item = profile("Q6 · prima della lettura", at: -50); item.recoveryReason = nil; return item }()
    library.insert(personalOld, at: 3); library.append(trashedRecovery); library.append(legacyRecovery)
    let pruned = ProfileLibrary.pruningRecoveryCopies(library)
    let keptRecovery = pruned.filter { $0.deletedAt == nil && $0.isRecoveryCopy }
    try require(keptRecovery.count == 20 && Set(keptRecovery.map(\.name)) == Set((5..<25).map { "R\($0)" }), "Only the 20 newest recovery copies remain")
    try require(pruned.contains(personalOld) && pruned.contains(trashedRecovery), "Older personal profiles and the trash are never pruned")
    try require(!pruned.contains(legacyRecovery), "Legacy-named recovery copies count as recovery copies")
    try require(pruned == library.filter { pruned.contains($0) }, "Pruning keeps the list order")
    try require(ProfileLibrary.pruningRecoveryCopies(pruned) == pruned, "At the limit nothing is removed")
    var manyPersonal = [KeyboardWorkspace](); for index in 0..<40 { manyPersonal.append(profile("P\(index)", at: Double(index))) }
    try require(ProfileLibrary.pruningRecoveryCopies(manyPersonal) == manyPersonal, "Personal profiles have no limit")

    let emptied = ProfileLibrary.emptyingTrash(library)
    try require(emptied.count == library.count - 1 && !emptied.contains(trashedRecovery) && emptied.contains(personalOld), "Emptying the trash removes only trashed profiles")

    let target = profile("Colore", at: 10), other = profile("Altro", at: 11)
    var edited = draft; edited.name = "Colore v2"; edited.recoveryReason = " · recupero"; edited.deletedAt = Date()
    let stamp = Date(timeIntervalSince1970: 999)
    let updated = try ProfileLibrary.updating([other, target], id: target.id, with: edited, at: stamp).unwrap("Update of the source profile")
    try require(updated.count == 2 && updated[0] == other, "Other profiles and positions are untouched")
    try require(updated[1].id == target.id && updated[1].name == "Colore v2" && updated[1].layers == edited.layers && updated[1].updatedAt == stamp, "The source profile takes the draft content and keeps its identity")
    try require(updated[1].deletedAt == nil && !updated[1].isRecoveryCopy, "An updated profile stays a personal profile")
    try require(ProfileLibrary.updating([other, target], id: nil, with: edited, at: stamp) == nil, "No source profile, no update")
    try require(ProfileLibrary.updating([other, target], id: UUID(), with: edited, at: stamp) == nil, "An unknown source is not created")
    var trashedTarget = target; trashedTarget.deletedAt = Date()
    try require(ProfileLibrary.updating([trashedTarget], id: target.id, with: edited, at: stamp) == nil, "A trashed profile is not overwritten")
    var recoveryTarget = target; recoveryTarget.recoveryReason = " · recupero"
    try require(ProfileLibrary.updatableIndex(target.id, in: [recoveryTarget]) == nil, "Recovery copies are not update targets")

    // Bounded entry: limits while typing and when editing ends.
    func typed(_ raw: String, _ range: ClosedRange<Int>) -> String { let r = BoundedInput.typing(raw, range: range); return "\(r.text)|\(r.value.map(String.init) ?? "nil")" }
    try require(typed("128", 0...255) == "128|128" && typed("0", 0...255) == "0|0", "Values inside the range pass unchanged")
    try require(typed("256", 0...255) == "255|255" && typed("99999999999999999999999", 0...255) == "255|255", "Typing above the maximum stops at the maximum, even past Int range")
    try require(typed("3600001", 0...3_600_000) == "3600000|3600000" && typed("3600000", 0...3_600_000) == "3600000|3600000", "Mix duration is capped at one hour")
    try require(typed("", 5...65535) == "|nil" && typed("1", 5...65535) == "1|nil" && typed("12", 5...65535) == "12|12", "Partial input below the minimum is allowed but not stored")
    try require(typed("1a2-3 ", 0...255) == "123|123" && typed("-5", 1...1092) == "5|5" && typed("1,5", 1...1092) == "15|15" && typed("007", 0...255) == "7|7", "Only digits are kept")
    try require(typed("1093", 1...1092) == "1092|1092" && typed("0", 1...1092) == "0|nil", "Sleep minutes stay within 1…1092")
    try require(BoundedInput.committed("0", range: 1...1092, previous: 10) == 1 && BoundedInput.committed("3", range: 5...65535, previous: 300) == 5, "Ending the edit applies the minimum")
    try require(BoundedInput.committed("", range: 5...65535, previous: 300) == 300 && BoundedInput.committed("abc", range: 0...255, previous: 999) == 255, "Empty text keeps the previous value, itself within the limits")
    try require(BoundedInput.committed("70000", range: 5...65535, previous: 300) == 65535 && BoundedInput.committed("999999999999999999999", range: 0...255, previous: 1) == 255, "Ending the edit applies the maximum")
    for value in [0, 1, 5, 255, 1092, 65535, 3_600_000] {
        for range in [0...255, 1...1092, 5...65535, 0...3_600_000] {
            let live = BoundedInput.typing(String(value), range: range).value, final = BoundedInput.committed(String(value), range: range, previous: range.lowerBound)
            try require(range.contains(final) && (live == nil || range.contains(live!)), "No path stores a value outside its range")
        }
    }
    try require(BoundedInput.hex("#57d9c1") == "57D9C1" && BoundedInput.hex(" ff b6 5b ") == "FFB65B" && BoundedInput.hex("57D9C1FF") == "57D9C1", "HEX entry drops #, spaces and extra digits")
    try require(BoundedInput.hex("red") == "ED" && !KeyboardWorkspace.validHex(BoundedInput.hex("red")) && BoundedInput.hex("１２３") == "", "Incomplete HEX stays visibly invalid; non-ASCII digits are dropped")
    try require(KeyboardWorkspace.validHex(BoundedInput.hex("#000000")), "A complete HEX entry is valid")
    print("Workspace: ISO matrix/LED mapping, lossless JSON roundtrip, opaque macro preservation and malformed profile guards, recovery-copy, pruning, trash, update and bounded-entry rules passed. No hardware or preferences access.")
} catch {
    fputs("Workspace test failure: \(error)\n", stderr)
    exit(1)
}
