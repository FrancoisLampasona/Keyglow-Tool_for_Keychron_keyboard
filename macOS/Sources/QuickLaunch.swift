import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

// Registers only explicitly selected hotkeys. No keyboard event monitor is used.
struct QuickLaunchModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32
    static let command = Self(rawValue: UInt32(cmdKey))
    static let option = Self(rawValue: UInt32(optionKey))
    static let control = Self(rawValue: UInt32(controlKey))
    static let shift = Self(rawValue: UInt32(shiftKey))
    static let allowed: Self = [.command, .option, .control, .shift]
    var label: String {
        [(Self.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { contains($0.0) }.map(\.1).joined()
    }
}

enum QuickLaunchTarget: String, Codable, CaseIterable, Sendable {
    case application, website
    var title: String { self == .application ? "Applicazione" : "Sito web" }
}

struct QuickLaunchRule: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var functionKey = 13
    var modifiers: QuickLaunchModifiers = []
    var target: QuickLaunchTarget = .application
    var destination = ""
    var enabled = true
    var shortcut: String { modifiers.label + "F\(functionKey)" }
    var shortcutIdentity: String { "\(functionKey):\(modifiers.rawValue)" }
}

struct QuickLaunchConfiguration: Codable, Sendable {
    var version = 1
    var enabled = false
    var rules: [QuickLaunchRule] = []
}

enum QuickLaunchError: LocalizedError {
    case invalid(String)
    case registration(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        case .registration(let status):
            if status == eventHotKeyExistsErr { return "Scorciatoia già usata da macOS o da un’altra app. Scegli un tasto o modificatori diversi." }
            return "macOS non ha registrato la scorciatoia (\(status)). Scegli una combinazione diversa e riprova."
        }
    }
}

@MainActor protocol QuickLaunchStoring {
    func load() -> Data?
    func save(_ data: Data)
}

@MainActor final class QuickLaunchUserDefaultsStore: QuickLaunchStoring {
    private let key = "quickLaunch.configuration.v1"
    func load() -> Data? { UserDefaults.standard.data(forKey: key) }
    func save(_ data: Data) { UserDefaults.standard.set(data, forKey: key) }
}

@MainActor protocol QuickLaunchRegistering {
    func install(handler: @escaping @MainActor (UInt32) -> Void) throws
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) throws
    func unregisterAll()
}

@MainActor final class CarbonQuickLaunchRegistrar: QuickLaunchRegistering {
    private var handler: (@MainActor (UInt32) -> Void)?
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private static let signature: OSType = 0x5453514C // TSQL

    func install(handler: @escaping @MainActor (UInt32) -> Void) throws {
        self.handler = handler
        guard eventHandler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == 0x5453514C else { return OSStatus(eventNotHandledErr) }
            let receiver = Unmanaged<CarbonQuickLaunchRegistrar>.fromOpaque(context).takeUnretainedValue()
            let id = hotKey.id
            DispatchQueue.main.async { receiver.handler?(id) }
            return noErr
        }
        let result = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard result == noErr else { throw QuickLaunchError.registration(result) }
    }

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) throws {
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else { throw QuickLaunchError.registration(result) }
        hotKeys.append(reference)
    }

    func unregisterAll() {
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        hotKeys.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        handler = nil
    }
}

@MainActor final class QuickLaunchService: ObservableObject {
    static let shared = QuickLaunchService()
    @Published private(set) var rules: [QuickLaunchRule] = []
    @Published private(set) var enabled = false
    @Published private(set) var registeredIDs = Set<UUID>()
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var message = "Avvio rapido disattivato. Aggiungi un’azione e attivalo quando sei pronto."
    private let storage: any QuickLaunchStoring
    private let registrar: any QuickLaunchRegistering
    private let opener: @MainActor (URL, QuickLaunchTarget) -> Void
    private var hotKeyRules: [UInt32: UUID] = [:]
    private var nextHotKeyID: UInt32 = 1

    /// The native SDK defines virtual keys only through F20. F21–F24 are not guessed.
    static let virtualKeys: [Int: UInt32] = [13: UInt32(kVK_F13), 14: UInt32(kVK_F14), 15: UInt32(kVK_F15), 16: UInt32(kVK_F16), 17: UInt32(kVK_F17), 18: UInt32(kVK_F18), 19: UInt32(kVK_F19), 20: UInt32(kVK_F20)]
    static var supportedFunctionKeys: [Int] { virtualKeys.keys.sorted() }

    init(storage: (any QuickLaunchStoring)? = nil, registrar: (any QuickLaunchRegistering)? = nil, opener: (@MainActor (URL, QuickLaunchTarget) -> Void)? = nil) {
        self.storage = storage ?? QuickLaunchUserDefaultsStore()
        self.registrar = registrar ?? CarbonQuickLaunchRegistrar()
        self.opener = opener ?? { url, target in
            if target == .application {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else { NSWorkspace.shared.open(url) }
        }
        if let data = self.storage.load() {
            do {
                let config = try JSONDecoder().decode(QuickLaunchConfiguration.self, from: data)
                guard config.version == 1, config.rules.count <= 64, Set(config.rules.map(\.id)).count == config.rules.count else { throw QuickLaunchError.invalid("Configurazione di Avvio rapido non valida. Le scorciatoie restano disattivate.") }
                rules = config.rules
                enabled = config.enabled
                if enabled { applyRegistrations() }
            } catch { message = "Non riesco a leggere le azioni salvate. Avvio rapido rimane disattivato." }
        }
    }

    static func destinationURL(for rule: QuickLaunchRule) throws -> URL {
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw QuickLaunchError.invalid("Assegna un nome all’azione.") }
        guard virtualKeys[rule.functionKey] != nil else { throw QuickLaunchError.invalid("Per Avvio rapido su macOS scegli un tasto tra F13 e F20.") }
        guard rule.modifiers.rawValue & ~QuickLaunchModifiers.allowed.rawValue == 0 else { throw QuickLaunchError.invalid("La combinazione contiene modificatori non supportati.") }
        switch rule.target {
        case .website:
            let text = rule.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme), let host = components.host, !host.isEmpty, components.user == nil, components.password == nil, let url = components.url else { throw QuickLaunchError.invalid("Inserisci un indirizzo completo, per esempio https://example.com.") }
            return url
        case .application:
            guard rule.destination.hasPrefix("/"), rule.destination.lowercased().hasSuffix(".app") else { throw QuickLaunchError.invalid("Scegli un’applicazione .app dal Mac.") }
            let url = URL(fileURLWithPath: rule.destination).standardizedFileURL
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw QuickLaunchError.invalid("L’applicazione non si trova più in quel percorso. Selezionala di nuovo.") }
            return url
        }
    }

    func setEnabled(_ newValue: Bool) {
        enabled = newValue
        applyRegistrations()
        persist()
    }

    func save(_ candidate: QuickLaunchRule) throws {
        _ = try Self.destinationURL(for: candidate)
        guard rules.count < 64 || rules.contains(where: { $0.id == candidate.id }) else { throw QuickLaunchError.invalid("Sono consentite al massimo 64 azioni.") }
        guard !rules.contains(where: { $0.id != candidate.id && $0.enabled && candidate.enabled && $0.shortcutIdentity == candidate.shortcutIdentity }) else { throw QuickLaunchError.invalid("Questa scorciatoia è già assegnata a un’altra azione di Keyglow.") }
        var rule = candidate
        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.destination = rule.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        applyRegistrations()
        persist()
    }

    func setRuleEnabled(_ id: UUID, _ newValue: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled = newValue
        applyRegistrations()
        persist()
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        applyRegistrations()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(QuickLaunchConfiguration(enabled: enabled, rules: rules)) { storage.save(data) }
    }

    private func applyRegistrations() {
        registrar.unregisterAll()
        hotKeyRules.removeAll(); registeredIDs.removeAll(); errors.removeAll()
        guard enabled else { message = "Avvio rapido disattivato. Nessuna scorciatoia globale registrata."; return }
        let active = rules.filter(\.enabled)
        guard !active.isEmpty else { message = "Aggiungi o abilita un’azione per registrare una scorciatoia."; return }
        do { try registrar.install { [weak self] id in self?.trigger(id) } }
        catch { message = error.localizedDescription; return }
        var seen = Set<String>()
        for rule in active {
            do {
                _ = try Self.destinationURL(for: rule)
                guard seen.insert(rule.shortcutIdentity).inserted else { throw QuickLaunchError.invalid("Scorciatoia duplicata in Keyglow. Modifica questa azione.") }
                let token = nextHotKeyID
                nextHotKeyID &+= 1
                if nextHotKeyID == 0 { nextHotKeyID = 1 }
                try registrar.register(keyCode: Self.virtualKeys[rule.functionKey]!, modifiers: rule.modifiers.rawValue, id: token)
                hotKeyRules[token] = rule.id
                registeredIDs.insert(rule.id)
            } catch { errors[rule.id] = error.localizedDescription }
        }
        message = errors.isEmpty ? "\(registeredIDs.count) scorciatoie attive. Lascia Keyglow aperta per usarle." : "\(registeredIDs.count) attive · \(errors.count) da correggere. Le azioni in errore non sono registrate."
    }

    private func trigger(_ token: UInt32) {
        guard enabled, let id = hotKeyRules[token], registeredIDs.contains(id), let rule = rules.first(where: { $0.id == id && $0.enabled }) else { return }
        do {
            let url = try Self.destinationURL(for: rule)
            opener(url, rule.target)
            message = "Avvio richiesto: \(rule.name)."
        } catch { errors[id] = error.localizedDescription; message = error.localizedDescription }
    }
}
