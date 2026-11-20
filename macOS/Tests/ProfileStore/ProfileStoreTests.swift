// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Stands in for the preferences: the old `profiles.v3` value and the marker.
@MainActor private final class FakeLegacy {
    var data: Data?
    var migrated = false
    var writes = 0
    var access: ProfileStore.Legacy {
        ProfileStore.Legacy(read: { self.data }, write: { self.data = $0; self.writes += 1 },
                            isMigrated: { self.migrated }, setMigrated: { self.migrated = $0 })
    }
}

@main @MainActor struct ProfileStoreTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func profile(_ name: String, _ code: UInt16 = 4) -> KeyboardWorkspace {
        var item = KeyboardWorkspace(); item.name = name; item.layers[1][7] = code
        item.macros[0].actions = [.init(kind: .text, text: "ciao"), .init(kind: .delay, milliseconds: 250)]
        item.lighting.perKey["0,0"] = "57D9C1"
        return item
    }
    private static func encoded(_ profiles: [KeyboardWorkspace]) -> Data { try! JSONEncoder().encode(profiles) }

    static func main() {
        // Everything happens in a throwaway directory. No preferences, no app data.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyglow-profile-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func directory(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        let a = profile("Colore"), b = profile("Lavoro", 5), c = profile("Giochi", 6)

        // Fresh install: nothing to migrate, files become the store.
        let freshLegacy = FakeLegacy()
        var fresh = ProfileStore(directory: directory("fresh"), legacy: freshLegacy.access)
        expect(fresh.load() == .init(profiles: [], source: .empty, notice: .none) && freshLegacy.migrated, "a fresh install starts on files")
        expect((try? fresh.save([a])) == .files && freshLegacy.data == nil && freshLegacy.writes == 0, "new profiles go to the file, not to preferences")
        var freshAgain = ProfileStore(directory: directory("fresh"), legacy: freshLegacy.access)
        expect(freshAgain.load() == .init(profiles: [a], source: .files, notice: .none), "saved profiles are read back from the file")

        // Migration: read the preference, write, read back, compare, then mark.
        let legacy = FakeLegacy(); legacy.data = encoded([a, b])
        let original = legacy.data
        var store = ProfileStore(directory: directory("migrate"), legacy: legacy.access)
        expect(store.load() == .init(profiles: [a, b], source: .legacy, notice: .none), "the first launch still shows the profiles from preferences")
        expect(legacy.migrated && exists(store.mainFile), "a verified copy marks the migration")
        expect(legacy.data == original && legacy.writes == 0, "the preference is neither deleted nor rewritten by the migration")
        var second = ProfileStore(directory: directory("migrate"), legacy: legacy.access)
        expect(second.load() == .init(profiles: [a, b], source: .files, notice: .none), "the next launch reads the files, with every field intact")
        expect((try? second.save([a, b, c])) == .files && legacy.data == original, "later saves leave the preference as the pre-migration copy")
        expect(exists(second.previousFile), "the previous good list is kept beside the new one")
        var third = ProfileStore(directory: directory("migrate"), legacy: legacy.access)
        expect(third.load().profiles == [a, b, c], "the new list is what loads")

        // Damaged main file: the previous list is used and the damaged file is kept.
        try! Data("{ not json".utf8).write(to: third.mainFile)
        var damaged = ProfileStore(directory: directory("migrate"), legacy: legacy.access)
        expect(damaged.load() == .init(profiles: [a, b], source: .previousFile, notice: .usedPreviousFile), "an unreadable file falls back to the previous list and says so")
        expect((try? damaged.save([a, b])) == .files, "saving after the fallback works")
        let unreadable = directory("migrate").appendingPathComponent("profiles.unreadable-1.json")
        expect(exists(unreadable) && (try? Data(contentsOf: unreadable)) == Data("{ not json".utf8), "the damaged file is set aside untouched, not deleted")
        expect(ProfileStore(directory: directory("migrate"), legacy: legacy.access).mainFile == damaged.mainFile && { var s = ProfileStore(directory: directory("migrate"), legacy: legacy.access); return s.load().source == .files }(), "the store is healthy again")

        // Both files unusable: back to the preference, without losing it.
        try! Data().write(to: damaged.mainFile); try! Data("[]x".utf8).write(to: damaged.previousFile)
        var lost = ProfileStore(directory: directory("migrate"), legacy: legacy.access)
        expect(lost.load() == .init(profiles: [a, b], source: .legacy, notice: .usedLegacyAfterMigration), "with no readable file the pre-migration preference is used and reported")
        expect(legacy.data == original && legacy.migrated, "the preference is intact and the files are rebuilt from it")
        try! FileManager.default.removeItem(at: directory("migrate"))
        var missing = ProfileStore(directory: directory("migrate"), legacy: legacy.access)
        expect(missing.load().profiles == [a, b] && exists(missing.mainFile), "a deleted folder is rebuilt from the preference")

        // Interrupted migration: a file exists but was never verified.
        let interrupted = FakeLegacy(); interrupted.data = encoded([a, b, c])
        var stale = ProfileStore(directory: directory("interrupted"), legacy: FakeLegacy().access)
        _ = stale.load(); _ = try? stale.save([a])
        var resumed = ProfileStore(directory: directory("interrupted"), legacy: interrupted.access)
        expect(!interrupted.migrated && resumed.load() == .init(profiles: [a, b, c], source: .legacy, notice: .none), "without the marker the preference wins over a leftover file")
        expect(interrupted.migrated && { var s = ProfileStore(directory: directory("interrupted"), legacy: interrupted.access); return s.load() == .init(profiles: [a, b, c], source: .files, notice: .none) }(), "the leftover file is replaced by a verified copy")
        let partialLegacy = FakeLegacy(); partialLegacy.data = encoded([b])
        try! FileManager.default.createDirectory(at: directory("partial"), withIntermediateDirectories: true)
        try! Data("{\"schema\":1,\"profiles\":[".utf8).write(to: directory("partial").appendingPathComponent("profiles.json"))
        var partial = ProfileStore(directory: directory("partial"), legacy: partialLegacy.access)
        expect(partial.load().profiles == [b] && partialLegacy.migrated, "a truncated file from an interrupted write is replaced after verification")

        // Files cannot be written: stay on the preference, lose nothing.
        let blocked = root.appendingPathComponent("blocked"); try! Data("file, not folder".utf8).write(to: blocked)
        let blockedLegacy = FakeLegacy(); blockedLegacy.data = encoded([a])
        var unwritable = ProfileStore(directory: blocked, legacy: blockedLegacy.access)
        expect(unwritable.load() == .init(profiles: [a], source: .legacy, notice: .none) && !blockedLegacy.migrated, "a failed copy never marks the migration")
        expect((try? unwritable.save([a, b])) == .legacy(reason: "") && blockedLegacy.data.flatMap { try? JSONDecoder().decode([KeyboardWorkspace].self, from: $0) } == [a, b] && !blockedLegacy.migrated, "saves keep going to the preference")
        var unwritableAgain = ProfileStore(directory: blocked, legacy: blockedLegacy.access)
        expect(unwritableAgain.load().profiles == [a, b], "and are read back from it")

        // Files stop being writable after the migration.
        let lateLegacy = FakeLegacy(); lateLegacy.data = encoded([a])
        var late = ProfileStore(directory: directory("late"), legacy: lateLegacy.access)
        _ = late.load()
        try! FileManager.default.removeItem(at: directory("late")); try! Data("x".utf8).write(to: directory("late"))
        if case .legacy(let reason)? = try? late.save([a, c]) { expect(!reason.isEmpty, "a failed file write reports its reason") } else { expect(false, "a failed file write falls back to the preference") }
        expect(lateLegacy.data.flatMap { try? JSONDecoder().decode([KeyboardWorkspace].self, from: $0) } == [a, c], "the list is stored in the preference")
        expect(!lateLegacy.migrated, "and that copy becomes current again")
        var lateAgain = ProfileStore(directory: directory("late"), legacy: lateLegacy.access)
        expect(lateAgain.load().profiles == [a, c], "nothing is lost at the next launch")

        // Unreadable preference and no files.
        let garbage = FakeLegacy(); garbage.data = Data("garbage".utf8)
        var empty = ProfileStore(directory: directory("garbage"), legacy: garbage.access)
        expect(empty.load() == .init(profiles: [], source: .empty, notice: .none) && garbage.data == Data("garbage".utf8) && !garbage.migrated, "an unreadable preference is left as it is")

        // Device backups: new folder only, newest 50 kept.
        let backups = directory("Keyglow-Backups"), old = directory("Tastiera-Backups")
        try! FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for index in 0..<3 { try! Data("old \(index)".utf8).write(to: old.appendingPathComponent("q6-max-2025-01-0\(index + 1)T10-00-00Z.json")) }
        try! FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try! Data("mine".utf8).write(to: backups.appendingPathComponent("notes.txt"))
        var written = [URL]()
        for index in 0..<60 { written.append(try! DeviceBackupStore.write(Data("backup \(index)".utf8), date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 90), in: backups)) }
        let kept = try! FileManager.default.contentsOfDirectory(atPath: backups.path).filter { $0.hasPrefix("q6-max-") }.sorted()
        expect(kept.count == 50 && kept == written.suffix(50).map(\.lastPathComponent), "only the newest 50 new backups remain")
        expect((try? Data(contentsOf: written[59])) == Data("backup 59".utf8) && exists(backups.appendingPathComponent("notes.txt")), "the latest backup is intact and other files are untouched")
        expect((try! FileManager.default.contentsOfDirectory(atPath: old.path)).count == 3, "backups in the old folder are never removed")
        let same = Date(timeIntervalSince1970: 1_900_000_000)
        let first = try! DeviceBackupStore.write(Data("one".utf8), date: same, in: backups), twin = try! DeviceBackupStore.write(Data("two".utf8), date: same, in: backups)
        expect(first != twin && (try? Data(contentsOf: first)) == Data("one".utf8) && (try? Data(contentsOf: twin)) == Data("two".utf8), "two backups in the same instant do not overwrite each other")
        expect((try? DeviceBackupStore.write(Data("x".utf8), date: same, in: blocked)) == nil, "an unwritable folder is an error, not a silent skip")
        print("Profile store: \(checks) checks passed (temporary directory and fake preferences; no app data touched).")
    }
}
