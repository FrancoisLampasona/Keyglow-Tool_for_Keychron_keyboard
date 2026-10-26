import Foundation

struct LightingDraft: Codable, Equatable, Sendable {
    var effect = 1
    var hue = 0.4692307692307692
    var saturation = 0.5990783410138248
    var value = 0.8509803921568627
    var brightness = 80.0
    var speed = 128.0
    var perKey: [String: String] = [:]
    var perKeyMode = 0
    var indicatorsDisabled = 0
    var indicatorHex = "57D9C1"
    var mix: [MixLayerDraft] = []
}
struct MixLayerDraft: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = "Livello RGB"
    var effect = 1
    var hex = "57D9C1"
    var speed = 128
    var brightness = 200
    var keys: [String] = []
    var durationMilliseconds = 1000
    var sequence: [MixEffectDraft] = []
}
struct MixEffectDraft: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var effect = 1
    var hex = "57D9C1"
    var speed = 128
    var durationMilliseconds = 1000
}
enum MacroActionKind: String, Codable, CaseIterable, Sendable {
    case text, tap, down, up, delay
    var title: String {
        switch self { case .text: "Testo"; case .tap: "Premi e rilascia"; case .down: "Premi"; case .up: "Rilascia"; case .delay: "Attendi" }
    }
}
struct MacroActionDraft: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: MacroActionKind = .text
    var text = ""
    var keycode: UInt16 = 4
    var milliseconds = 100
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.kind == rhs.kind && lhs.text == rhs.text && lhs.keycode == rhs.keycode && lhs.milliseconds == rhs.milliseconds }
}
struct MacroDraft: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var name: String
    var actions: [MacroActionDraft] = []
    var rawBytes: [UInt8]? = nil
}
struct AdvancedDraft: Codable, Equatable, Sendable {
    var sleepEnabled = true
    var sleepMinutes = 10
    var nkro = false
    var debounce = 5
    var backlightSeconds = 300
}
struct KeyboardWorkspace: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    var name = "La mia Q6 Max"
    var model = "keychron/q6_max/iso_encoder"
    var language = "it-IT"
    var updatedAt = Date()
    var origin = "Configurazione locale · valori di fabbrica ufficiali"
    var layers: [[UInt16]]
    var encoders: [[UInt16]]
    var macros: [MacroDraft]
    var lighting = LightingDraft()
    var advanced = AdvancedDraft()
    init() {
        layers = KeyboardDefinition.q6ISO.defaultLayers
        encoders = KeyboardDefinition.q6ISO.defaultEncoders
        macros = (0..<16).map { MacroDraft(id: $0, name: "Macro \($0 + 1)") }
    }
    func validate() throws {
        guard schemaVersion == 1, model == "keychron/q6_max/iso_encoder", layers.count == 4,
              layers.allSatisfy({ $0.count == 120 }), encoders.count == 4, encoders.allSatisfy({ $0.count == 2 }),
              (1...64).contains(macros.count), macros.enumerated().allSatisfy({ $0.offset == $0.element.id }),
              macros.allSatisfy({ $0.id >= 0 && $0.id < 64 && ($0.rawBytes?.count ?? 0) <= 65535 && $0.actions.count < 10000 && $0.actions.allSatisfy({ $0.milliseconds >= 0 && $0.milliseconds <= 65535 && $0.text.utf8.count < 65536 && ($0.kind == .text || $0.kind == .delay || (1...255).contains($0.keycode)) }) }),
              (0...24).contains(lighting.effect), [lighting.hue, lighting.saturation, lighting.value].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              lighting.brightness.isFinite, (0...100).contains(lighting.brightness), lighting.speed.isFinite, (0...255).contains(lighting.speed),
              lighting.perKey.count <= 110, lighting.mix.count <= 16,
              (0...4).contains(lighting.perKeyMode), (0...255).contains(lighting.indicatorsDisabled), Self.validHex(lighting.indicatorHex),
              (5...65535).contains(advanced.backlightSeconds), (1...1092).contains(advanced.sleepMinutes) else { throw WorkspaceError.invalid }
        let ids = Set(KeyboardDefinition.q6ISO.keys.map(\.id))
        guard lighting.perKey.allSatisfy({ ids.contains($0.key) && Self.validHex($0.value) }),
              lighting.mix.allSatisfy({ (0...22).contains($0.effect) && (0...255).contains($0.speed) && (0...255).contains($0.brightness) && Self.validHex($0.hex) && $0.keys.allSatisfy(ids.contains) && $0.sequence.count <= 64 && $0.sequence.allSatisfy({ (0...22).contains($0.effect) && (0...255).contains($0.speed) && (0...3600000).contains($0.durationMilliseconds) && Self.validHex($0.hex) }) }) else { throw WorkspaceError.invalid }
    }
    static func validHex(_ s: String) -> Bool { s.count == 6 && s.allSatisfy(\.isHexDigit) && UInt32(s, radix:16) != nil }
}
enum WorkspaceError: LocalizedError {
    case invalid, tooLarge
    var errorDescription: String? { self == .invalid ? "Il file non è un profilo valido per Keychron Q6 Max ISO. Nessuna impostazione è stata modificata." : "Il file supera il limite di 2 MB." }
}
struct RGBEffect: Identifiable, Sendable {
    let id: Int
    let name: String
    let symbol: String
    var usesColor: Bool { [1,2,3,18,19,20,22,23,24].contains(id) }
    var usesSpeed: Bool { id > 1 && id < 23 }
    static let all: [RGBEffect] = [
        .init(id:0,name:"Spento",symbol:"power"),.init(id:1,name:"Colore fisso",symbol:"circle.fill"),.init(id:2,name:"Respiro",symbol:"waveform.path"),
        .init(id:3,name:"Spirale a bande",symbol:"hurricane"),.init(id:4,name:"Ciclo completo",symbol:"circle.lefthalf.filled"),.init(id:5,name:"Ciclo orizzontale",symbol:"arrow.left.and.right"),
        .init(id:6,name:"Ciclo verticale",symbol:"arrow.up.and.down"),.init(id:7,name:"Chevron arcobaleno",symbol:"chevron.forward.2"),.init(id:8,name:"Ciclo radiale",symbol:"arrow.up.left.and.arrow.down.right"),
        .init(id:9,name:"Ciclo radiale doppio",symbol:"arrow.down.right.and.arrow.up.left"),.init(id:10,name:"Girandola",symbol:"fanblades"),.init(id:11,name:"Spirale",symbol:"hurricane"),
        .init(id:12,name:"Doppio faro",symbol:"light.beacon.max"),.init(id:13,name:"Faro arcobaleno",symbol:"light.beacon.min"),.init(id:14,name:"Gocce colorate",symbol:"drop"),
        .init(id:15,name:"Pioggia di pixel",symbol:"square.grid.3x3"),.init(id:16,name:"Mappa di calore",symbol:"flame"),.init(id:17,name:"Pioggia digitale",symbol:"cloud.rain"),
        .init(id:18,name:"Reattivo semplice",symbol:"dot.radiowaves.left.and.right"),.init(id:19,name:"Reattivo ampio",symbol:"waveform.path"),.init(id:20,name:"Reattivo nexus",symbol:"sparkles"),
        .init(id:21,name:"Splash",symbol:"water.waves"),.init(id:22,name:"Splash fisso",symbol:"water.waves"),.init(id:23,name:"RGB per tasto",symbol:"keyboard"),.init(id:24,name:"Mix RGB",symbol:"square.3.layers.3d")
    ]
}
