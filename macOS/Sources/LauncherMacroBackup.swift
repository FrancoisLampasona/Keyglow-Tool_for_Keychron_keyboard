import Foundation
import CoreFoundation
import CryptoKit

/// Launcher keyboard macro JSON, observed in chunk 144 / module 85144 (2026-10-26).
/// Keeps slot order and event meaning. It does not write to hardware or infer capacity.
enum LauncherMacroBackup {
    private static let deviceID = 875_825_249 // 65536 * 0x3434 + 0x0861
    private static let maximumFileSize = 2_000_000

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): message }
        }
    }

    /// Exports every supplied slot, including empty slots. IDs must be 0...count-1.
    static func encode(macros: [MacroDraft]) throws -> Data {
        guard (1...64).contains(macros.count), macros.enumerated().allSatisfy({ $0.offset == $0.element.id }) else {
            throw Failure.invalid("Le macro Launcher devono mantenere gli slot consecutivi, da M0 in poi (massimo 64).")
        }
        let slots = try macros.map { macro -> String in
            guard macro.rawBytes == nil else {
                throw Failure.invalid("M\(macro.id) contiene un buffer originale non decodificabile. Conservalo nel backup Keyglow: non può essere convertito nel formato Launcher senza perdere dati.")
            }
            guard macro.actions.count < 10_000, macro.name.utf8.count <= 4096 else {
                throw Failure.invalid("La macro M\(macro.id) supera i limiti del file di importazione.")
            }
            let events = try macro.actions.map { action -> String in
                switch action.kind {
                case .text:
                    try validateText(action.text)
                    return "[5,\(jsonString(action.text))]"
                case .delay:
                    try validateDelay(action.milliseconds)
                    return "[4,\(action.milliseconds)]"
                case .tap, .down, .up:
                    guard let symbol = symbolByCode[action.keycode] else {
                        throw Failure.invalid(String(format: "Il keycode 0x%04X non ha una corrispondenza tastiera provata nel formato macro Launcher; la macro non è stata convertita.", Int(action.keycode)))
                    }
                    let event = action.kind == .tap ? 1 : action.kind == .down ? 2 : 3
                    let label = KeycodeCatalog.display(action.keycode)
                    return "[\(event),\(jsonString(label)),\(jsonString(symbol))]"
                }
            }
            return "[" + events.joined(separator: ",") + "]"
        }
        let macroJSON = "[" + slots.joined(separator: ",") + "]"
        let names = "[" + macros.map { jsonString($0.name) }.joined(separator: ",") + "]"
        let data = Data("{\"md5\":\"\(digest(macroJSON + String(deviceID)))\",\"macro\":\(macroJSON),\"name\":\(names)}".utf8)
        guard data.count <= maximumFileSize else { throw Failure.invalid("Il file macro supera il limite di 2 MB.") }
        return data
    }

    /// Imports the current format. The checksum binds the event arrays to Q6 Max ISO.
    /// Names are cosmetic and are not protected by Launcher's digest; event labels are.
    static func decode(_ data: Data) throws -> [MacroDraft] {
        let object = try parse(data)
        guard let root = object as? [String: Any], Set(root.keys) == Set(["md5", "macro", "name"]),
              let checksum = root["md5"] as? String, checksum.utf8.count == 32,
              let names = root["name"] as? [String] else {
            throw Failure.invalid("Serve un file macro Launcher con md5, macro e name. Il vecchio formato senza checksum richiede l’importazione legacy esplicita.")
        }
        let converted = try convert(root["macro"], names: names, legacy: false)
        guard digest(converted.canonical + String(deviceID)) == checksum else {
            throw Failure.invalid("Checksum macro Launcher non valido oppure file appartenente a una tastiera diversa dalla Q6 Max ISO.")
        }
        return converted.macros
    }

    /// The old editor exported the bare macro array. It has no device identity,
    /// checksum, names, or protocol version; callers must label this explicitly.
    /// Only symbols whose numeric value is identical in all observed enums are read.
    static func decodeLegacy(_ data: Data) throws -> [MacroDraft] {
        let object = try parse(data)
        guard let slots = object as? [Any] else { throw Failure.invalid("Il formato legacy Launcher deve essere un array di slot macro.") }
        return try convert(slots, names: slots.indices.map { "Macro \($0 + 1)" }, legacy: true).macros
    }

    private static func parse(_ data: Data) throws -> Any {
        guard data.count <= maximumFileSize else { throw Failure.invalid("Il file macro supera il limite di 2 MB.") }
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw Failure.invalid("Il file macro non contiene JSON valido.") }
    }

    private static func convert(_ value: Any?, names: [String], legacy: Bool) throws -> (macros: [MacroDraft], canonical: String) {
        guard let slots = value as? [Any], (1...64).contains(slots.count), names.count == slots.count,
              names.allSatisfy({ $0.utf8.count <= 4096 }) else {
            throw Failure.invalid("Il file deve contenere da 1 a 64 slot e un nome per ciascuno slot, compresi quelli vuoti.")
        }
        var macros = [MacroDraft](), serializedSlots = [String]()
        for (slotIndex, slot) in slots.enumerated() {
            guard let events = slot as? [Any], events.count < 10_000 else { throw Failure.invalid("Lo slot M\(slotIndex) non contiene una sequenza valida.") }
            var actions = [MacroActionDraft](), serializedEvents = [String]()
            for (eventIndex, rawEvent) in events.enumerated() {
                let location = "M\(slotIndex), azione \(eventIndex + 1)"
                guard let event = rawEvent as? [Any], let rawType = event.first, let type = integer(rawType) else {
                    throw Failure.invalid("\(location): evento macro non valido.")
                }
                switch type {
                case 1, 2, 3:
                    guard event.count == 3, let label = event[1] as? String, label.utf8.count <= 4096,
                          let symbol = event[2] as? String, let code = codeBySymbol[symbol] else {
                        throw Failure.invalid("\(location): simbolo di tasto sconosciuto o evento mouse non supportato. Il file originale non è stato modificato.")
                    }
                    guard !legacy || !["KC_MIC", "KC_LPAD"].contains(symbol) else {
                        throw Failure.invalid("\(location): \(symbol) cambia valore tra le versioni legacy; manca la versione del protocollo per convertirlo senza ambiguità.")
                    }
                    let kind: MacroActionKind = type == 1 ? .tap : type == 2 ? .down : .up
                    actions.append(MacroActionDraft(kind: kind, keycode: code))
                    serializedEvents.append("[\(type),\(jsonString(label)),\(jsonString(symbol))]")
                case 4:
                    guard event.count == 2, let milliseconds = integer(event[1]) else { throw Failure.invalid("\(location): ritardo macro non valido.") }
                    try validateDelay(milliseconds)
                    actions.append(MacroActionDraft(kind: .delay, milliseconds: milliseconds))
                    serializedEvents.append("[4,\(milliseconds)]")
                case 5:
                    guard event.count == 2, let text = event[1] as? String else { throw Failure.invalid("\(location): testo macro non valido.") }
                    try validateText(text)
                    actions.append(MacroActionDraft(kind: .text, text: text))
                    serializedEvents.append("[5,\(jsonString(text))]")
                default:
                    throw Failure.invalid("\(location): comando Launcher \(type) non supportato da questo editor (inclusi mouse e combinazioni 6/7). Nessun comando è stato scartato o sostituito.")
                }
            }
            macros.append(MacroDraft(id: slotIndex, name: names[slotIndex], actions: actions))
            serializedSlots.append("[" + serializedEvents.joined(separator: ",") + "]")
        }
        return (macros, "[" + serializedSlots.joined(separator: ",") + "]")
    }

    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= 65_535, value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
    private static func validateDelay(_ delay: Int) throws {
        guard (0...65_535).contains(delay) else { throw Failure.invalid("Il ritardo macro deve essere un intero tra 0 e 65535 ms.") }
    }
    private static func validateText(_ text: String) throws {
        guard text.utf8.count < 65_536, text.utf8.allSatisfy({ $0 >= 2 && $0 < 128 }) else {
            throw Failure.invalid("Il testo macro richiede ASCII senza i byte riservati 0 e 1. Caratteri non rappresentabili non vengono convertiti o rimossi.")
        }
    }
    private static func digest(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// ECMAScript JSON.stringify escaping, including lowercase control escapes and
    /// literal slash/U+2028/U+2029. All numbers in supported events are small integers.
    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 8: result += "\\b"
            case 12: result += "\\f"
            case 10: result += "\\n"
            case 13: result += "\\r"
            case 9: result += "\\t"
            case 0...31: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    // Exact KC_* assignments from Launcher module 44040 enums y/L (VIA 11/12/13).
    // Mouse commands intentionally excluded: they are not MacroActionDraft events.
    // Last alias wins in the reverse enum, matching TypeScript's emitted enum code.
    private static let keySymbols = """
    1:KC_TRNS 4:KC_A 5:KC_B 6:KC_C 7:KC_D 8:KC_E 9:KC_F 10:KC_G
    11:KC_H 12:KC_I 13:KC_J 14:KC_K 15:KC_L 16:KC_M 17:KC_N 18:KC_O
    19:KC_P 20:KC_Q 21:KC_R 22:KC_S 23:KC_T 24:KC_U 25:KC_V 26:KC_W
    27:KC_X 28:KC_Y 29:KC_Z 30:KC_1 31:KC_2 32:KC_3 33:KC_4 34:KC_5
    35:KC_6 36:KC_7 37:KC_8 38:KC_9 39:KC_0 40:KC_ENT 41:KC_ESC 42:KC_BSPC
    43:KC_TAB 44:KC_SPC 45:KC_MINS 46:KC_EQL 47:KC_LBRC 48:KC_RBRC 49:KC_BSLS 50:KC_NUHS
    51:KC_SCLN 52:KC_QUOT 53:KC_GRV 54:KC_COMM 55:KC_DOT 56:KC_SLSH 57:KC_CAPS 58:KC_F1
    59:KC_F2 60:KC_F3 61:KC_F4 62:KC_F5 63:KC_F6 64:KC_F7 65:KC_F8 66:KC_F9
    67:KC_F10 68:KC_F11 69:KC_F12 70:KC_PSCR 71:KC_SLCK 72:KC_PAUS 73:KC_INS 74:KC_HOME
    75:KC_PGUP 76:KC_DEL 77:KC_END 78:KC_PGDN 79:KC_RGHT 80:KC_LEFT 81:KC_DOWN 82:KC_UP
    83:KC_NLCK 84:KC_PSLS 85:KC_PAST 86:KC_PMNS 87:KC_PPLS 88:KC_PENT 89:KC_P1 90:KC_P2
    91:KC_P3 92:KC_P4 93:KC_P5 94:KC_P6 95:KC_P7 96:KC_P8 97:KC_P9 98:KC_P0
    99:KC_PDOT 100:KC_NUBS 101:KC_APP 102:KC_POWER 103:KC_PEQL 104:KC_F13 105:KC_F14 106:KC_F15
    107:KC_F16 108:KC_F17 109:KC_F18 110:KC_F19 111:KC_F20 112:KC_F21 113:KC_F22 114:KC_F23
    115:KC_F24 116:KC_EXECUTE 117:KC_HELP 118:KC_MENU 119:KC_SELECT 120:KC_STOP 121:KC_AGAIN 122:KC_UNDO
    123:KC_CUT 124:KC_COPY 125:KC_PASTE 126:KC_FIND 130:KC_LCAP 131:KC_LNUM 132:KC_LSCR 133:KC_PCMM
    134:KC_KP_EQUAL_AS400 135:KC_RO 136:KC_KANA 137:KC_JYEN 138:KC_HENK 139:KC_MHEN 140:KC_INT6 141:KC_INT7
    142:KC_INT8 143:KC_INT9 144:KC_HAEN 145:KC_HANJ 146:KC_LANG3 147:KC_LANG4 148:KC_LANG5 149:KC_LANG6
    150:KC_LANG7 151:KC_LANG8 152:KC_LANG9 153:KC_ERAS 154:KC_SYSREQ 155:KC_CANCEL 156:KC_CLR 156:KC_CLEAR
    157:KC_PRIOR 160:KC_OUT 161:KC_OPER 162:KC_CLEAR_AGAIN 163:KC_CRSEL 164:KC_EXSEL 165:KC_PWR 166:KC_SLEP
    167:KC_WAKE 168:KC_MUTE 169:KC_VOLU 170:KC_VOLD 171:KC_MNXT 172:KC_MPRV 173:KC_MSTP 174:KC_MPLY
    175:KC_MSEL 176:KC_EJCT 177:KC_MAIL 178:KC_CALC 179:KC_MYCM 180:KC_WWW_SEARCH 181:KC_WWW_HOME 182:KC_WWW_BACK
    183:KC_WWW_FORWARD 184:KC_WWW_STOP 185:KC_WWW_REFRESH 186:KC_WWW_FAVORITES 187:KC_MFFD 188:KC_MRWD 189:KC_BRIU 190:KC_BRID
    224:KC_LCTL 225:KC_LSFT 226:KC_LALT 227:KC_LGUI 228:KC_RCTL 229:KC_RSFT 230:KC_RALT 231:KC_RGUI
    194:KC_LPAD 193:KC_MIC
    """
    private static let pairs: [(UInt16, String)] = keySymbols.split(whereSeparator: \.isWhitespace).map { entry in
        let fields = entry.split(separator: ":")
        return (UInt16(fields[0])!, String(fields[1]))
    }
    private static let codeBySymbol: [String: UInt16] = Dictionary(uniqueKeysWithValues: pairs.map { ($0.1, $0.0) })
    private static let symbolByCode: [UInt16: String] = pairs.reduce(into: [:]) { $0[$1.0] = $1.1 }
}
