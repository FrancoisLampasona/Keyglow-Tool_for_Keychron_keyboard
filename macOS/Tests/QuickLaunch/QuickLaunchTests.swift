import AppKit
import Carbon
import Foundation

@MainActor final class MemoryQuickLaunchStore: QuickLaunchStoring {
    var data: Data?
    var saves = 0
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data; saves += 1 }
}

@MainActor final class FakeQuickLaunchRegistrar: QuickLaunchRegistering {
    var installCount = 0
    var unregisterCount = 0
    var registered: [(UInt32, UInt32, UInt32)] = []
    var conflictKey: UInt32?
    var handler: (@MainActor (UInt32) -> Void)?
    func install(handler: @escaping @MainActor (UInt32) -> Void) throws { installCount += 1; self.handler = handler }
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) throws {
        if keyCode == conflictKey { throw QuickLaunchError.registration(OSStatus(eventHotKeyExistsErr)) }
        registered.append((keyCode, modifiers, id))
    }
    func unregisterAll() { unregisterCount += 1; registered = []; handler = nil }
}

@main @MainActor struct QuickLaunchTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ text: String) { if !condition() { fatalError(text) } }
    static func main() throws {
        let storage = MemoryQuickLaunchStore()
        let registrar = FakeQuickLaunchRegistrar()
        var requestedURLs: [URL] = []
        let service = QuickLaunchService(storage: storage, registrar: registrar, opener: { url, _ in requestedURLs.append(url) })
        expect(!service.enabled && service.rules.isEmpty, "default is off and empty")
        expect(registrar.installCount == 0 && registrar.unregisterCount == 0 && registrar.registered.isEmpty, "init off has no OS registration path")
        var rule = QuickLaunchRule(name: "Documentazione", functionKey: 13, modifiers: [.command, .option], target: .website, destination: "https://example.com/docs")
        try service.save(rule)
        expect(registrar.installCount == 0 && registrar.registered.isEmpty, "saving while off does not register")
        expect(requestedURLs.isEmpty, "saving does not open destination")
        service.setEnabled(true)
        expect(registrar.registered.count == 1, "explicit enable registers")
        expect(registrar.registered[0].0 == UInt32(kVK_F13), "F13 code from SDK")
        expect(registrar.registered[0].1 == UInt32(cmdKey | optionKey), "modifiers")
        let firstToken = registrar.registered[0].2
        registrar.handler?(firstToken)
        expect(requestedURLs.map(\.absoluteString) == ["https://example.com/docs"], "selected hotkey invokes injected opener only")
        rule.functionKey = 14
        try service.save(rule)
        expect(registrar.registered.count == 1 && registrar.registered[0].0 == UInt32(kVK_F14), "edit unregisters prior and registers replacement")
        let newToken = registrar.registered[0].2
        expect(newToken != firstToken, "new registration has fresh event identity")
        registrar.handler?(firstToken)
        expect(requestedURLs.count == 1, "stale queued event cannot invoke replacement rule")
        registrar.handler?(newToken)
        expect(requestedURLs.count == 2, "replacement hotkey")
        var duplicate = rule; duplicate.id = UUID()
        do { try service.save(duplicate); fatalError("duplicate shortcut accepted") } catch { }
        var invalid = QuickLaunchRule(name: "Invalid", target: .website, destination: "file:///etc/passwd")
        do { try service.save(invalid); fatalError("file URL accepted") } catch { }
        invalid.destination = "https://user:password@example.com"
        do { _ = try QuickLaunchService.destinationURL(for: invalid); fatalError("credentials URL accepted") } catch { }
        invalid.destination = "https://example.com"; invalid.functionKey = 24
        do { _ = try QuickLaunchService.destinationURL(for: invalid); fatalError("unverified F24 mapping accepted") } catch { }
        let second = QuickLaunchRule(name: "Conflitto", functionKey: 15, target: .website, destination: "http://example.org")
        registrar.conflictKey = UInt32(kVK_F15)
        try service.save(second)
        expect(service.errors[second.id] != nil && !service.registeredIDs.contains(second.id), "system conflict visible and unregistered")
        expect(service.registeredIDs.contains(rule.id), "unrelated rule stays active")
        service.setEnabled(false)
        expect(registrar.registered.isEmpty && registrar.handler == nil, "disable unregisters all and removes callback")
        expect(requestedURLs.count == 2, "configuration never opens other URLs")
        let restoredBackend = FakeQuickLaunchRegistrar()
        let restored = QuickLaunchService(storage: storage, registrar: restoredBackend, opener: { _, _ in fatalError("restored rule opened") })
        expect(restored.rules.count == 2 && !restored.enabled, "names and rules persist")
        expect(restoredBackend.installCount == 0 && restoredBackend.unregisterCount == 0, "disabled persisted config does not install handler")
        restored.remove(rule.id)
        expect(restored.rules.map(\.id) == [second.id], "remove persists exact rule")
        let brokenStore = MemoryQuickLaunchStore(); brokenStore.data = Data("garbage".utf8)
        let brokenBackend = FakeQuickLaunchRegistrar()
        let broken = QuickLaunchService(storage: brokenStore, registrar: brokenBackend)
        expect(!broken.enabled && brokenBackend.installCount == 0 && broken.rules.isEmpty, "malformed storage cannot enable")
        expect(QuickLaunchService.supportedFunctionKeys == Array(13...20), "only documented virtual function keys")
        print("QuickLaunch: default-off, save/load, explicit activation, modifier mapping, duplicate and OS conflicts, stale-event guard, URL validation, unregister and corrupt-storage tests passed. No real hotkeys registered or destinations opened.")
    }
}
