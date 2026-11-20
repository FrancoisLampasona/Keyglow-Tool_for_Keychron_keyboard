// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Saved profiles as files in Application Support, migrated from the
/// `profiles.v3` preference. The preference is never deleted: it stays as the
/// copy from before the migration and as the fallback when files cannot be used.
/// No UI, no device access; the directory and the preference access are injected.
struct ProfileStore {
    /// Access to the pre-file storage and to the "migration verified" marker.
    struct Legacy {
        var read: () -> Data?
        var write: (Data) -> Void
        var isMigrated: () -> Bool
        var setMigrated: (Bool) -> Void
    }
    enum Source: Equatable { case files, previousFile, legacy, empty }
    enum Notice: Equatable { case none, usedPreviousFile, usedLegacyAfterMigration }
    struct Loaded: Equatable { var profiles: [KeyboardWorkspace]; var source: Source; var notice: Notice }
    enum Saved: Equatable { case files, legacy(reason: String) }
    private struct Envelope: Codable { var schema = 1; var profiles: [KeyboardWorkspace] }

    static let legacyKey = "profiles.v3"
    static let migratedKey = "profiles.fileStoreVersion"
    let directory: URL
    let legacy: Legacy
    /// True while the main file is known to hold a readable, current list.
    private(set) var mainIsReadable = false
    var mainFile: URL { directory.appendingPathComponent("profiles.json") }
    var previousFile: URL { directory.appendingPathComponent("profiles.previous.json") }

    init(directory: URL, legacy: Legacy) { self.directory = directory; self.legacy = legacy }

    static func standard(defaults: UserDefaults = .standard) -> ProfileStore {
        let root = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Keyglow/Profiles", isDirectory: true)
        return ProfileStore(directory: root, legacy: Legacy(
            read: { defaults.data(forKey: legacyKey) },
            write: { defaults.set($0, forKey: legacyKey) },
            isMigrated: { defaults.integer(forKey: migratedKey) >= 1 },
            setMigrated: { defaults.set($0 ? 1 : 0, forKey: migratedKey) }))
    }

    private func readFile(_ url: URL) -> [KeyboardWorkspace]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.profiles
    }
    private func readLegacy() -> [KeyboardWorkspace]? {
        legacy.read().flatMap { try? JSONDecoder().decode([KeyboardWorkspace].self, from: $0) }
    }
    private func writeMain(_ profiles: [KeyboardWorkspace]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Envelope(profiles: profiles)).write(to: mainFile, options: .atomic)
    }
    /// Write the files from the preference, read them back and compare. Only a
    /// verified copy sets the marker; otherwise the preference stays in use.
    private mutating func migrate(_ profiles: [KeyboardWorkspace]) {
        mainIsReadable = false
        guard (try? writeMain(profiles)) != nil, readFile(mainFile) == profiles else { legacy.setMigrated(false); return }
        mainIsReadable = true; legacy.setMigrated(true)
    }

    mutating func load() -> Loaded {
        mainIsReadable = false
        if legacy.isMigrated() {
            if let profiles = readFile(mainFile) { mainIsReadable = true; return Loaded(profiles: profiles, source: .files, notice: .none) }
            if let profiles = readFile(previousFile) { return Loaded(profiles: profiles, source: .previousFile, notice: .usedPreviousFile) }
            // Files are missing or unreadable: the preference still holds the
            // list from before the migration. Use it and rebuild the files.
            guard let profiles = readLegacy() else { return Loaded(profiles: [], source: .empty, notice: .none) }
            setAsideUnreadableMain()
            migrate(profiles)
            return Loaded(profiles: profiles, source: .legacy, notice: profiles.isEmpty ? .none : .usedLegacyAfterMigration)
        }
        // Not migrated, or a migration was interrupted before it was verified:
        // every save so far went to the preference, which is therefore current.
        guard let profiles = readLegacy() else {
            // No preference at all (a new Mac, or preferences were reset): files
            // that already hold profiles are adopted, never overwritten with nothing.
            if legacy.read() == nil {
                if let existing = readFile(mainFile) {
                    mainIsReadable = true; legacy.setMigrated(true)
                    return Loaded(profiles: existing, source: .files, notice: .none)
                }
                if let previous = readFile(previousFile) {
                    legacy.setMigrated(true)
                    return Loaded(profiles: previous, source: .previousFile, notice: .usedPreviousFile)
                }
                migrate([])
            }
            return Loaded(profiles: [], source: .empty, notice: .none)
        }
        migrate(profiles)
        return Loaded(profiles: profiles, source: .legacy, notice: .none)
    }

    /// Throws only when the list cannot be encoded; nothing is changed then.
    @discardableResult mutating func save(_ profiles: [KeyboardWorkspace]) throws -> Saved {
        let legacyData = try JSONEncoder().encode(profiles)
        guard legacy.isMigrated() else {
            legacy.write(legacyData)
            migrate(profiles)
            return .legacy(reason: "")
        }
        do {
            if mainIsReadable {
                // Keep the last good list beside the new one.
                _ = try? FileManager.default.removeItem(at: previousFile)
                try? FileManager.default.copyItem(at: mainFile, to: previousFile)
            } else { setAsideUnreadableMain() }
            try writeMain(profiles)
            mainIsReadable = true
            return .files
        } catch {
            // Never lose the list: store it where it was before the migration and
            // make that copy authoritative again until files work.
            legacy.write(legacyData); legacy.setMigrated(false); mainIsReadable = false
            return .legacy(reason: error.localizedDescription)
        }
    }
    /// A damaged file is kept for inspection, never deleted or reused as "previous".
    private func setAsideUnreadableMain() {
        guard FileManager.default.fileExists(atPath: mainFile.path), readFile(mainFile) == nil else { return }
        var index = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent("profiles.unreadable-\(index).json").path) { index += 1 }
        try? FileManager.default.moveItem(at: mainFile, to: directory.appendingPathComponent("profiles.unreadable-\(index).json"))
    }
}

/// Snapshots of the keyboard configuration taken before a USB apply.
enum DeviceBackupStore {
    static let limit = 50
    static let prefix = "q6-max-", suffix = ".json"
    static var standardDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Keyglow/Backups", isDirectory: true)
    }
    /// Writes one backup and keeps the newest `limit` in this directory only.
    /// Other folders, including backups made by earlier versions, are never touched.
    @discardableResult static func write(_ data: Data, date: Date, in directory: URL, limit: Int = limit) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        var url = directory.appendingPathComponent("\(prefix)\(stamp)\(suffix)"), copy = 2
        while FileManager.default.fileExists(atPath: url.path) { url = directory.appendingPathComponent("\(prefix)\(stamp)-\(copy)\(suffix)"); copy += 1 }
        try data.write(to: url, options: .atomic)
        // Names sort by time. Only files this function names are candidates.
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.sorted()
        for name in names.dropLast(max(1, limit)) where name != url.lastPathComponent {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return url
    }
}
