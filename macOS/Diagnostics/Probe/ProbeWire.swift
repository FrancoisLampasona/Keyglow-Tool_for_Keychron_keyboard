import Foundation

enum ProbeFailure: String, Error, Sendable {
    case invalidNonce, invalidInterval, inputActivity, malformedInput, unexpectedMarker, responseBeforeRequest
    case wrongResponse, wrongNonce, wrongCRC, disconnected, deadline, cancelled
    case noDevice, ambiguousDevice, incompatibleDescriptor, permissionDenied, openFailed
    case snapshotFailed, invalidSnapshot, writeFailed, restoreFailed, resultSaveFailed

    var message: String {
        switch self {
        case .invalidInterval: return "La pausa LED deve essere compresa tra 20 e 80 ms. Nessun comando inviato."
        case .inputActivity: return "Prova interrotta perché è stato premuto un tasto. Nessuna digitazione è stata registrata."
        case .disconnected: return "La tastiera si è scollegata. Ripeti la prova dopo il ricollegamento."
        case .deadline: return "Nessuna risposta completa entro il limite. Il canale Bluetooth di ritorno non è confermato."
        case .cancelled: return "Prova interrotta."
        case .noDevice: return "Q6 Max ISO Bluetooth non trovata. Controlla il selettore BT e il collegamento."
        case .ambiguousDevice: return "È presente più di una Q6 Max ISO. Nessun comando inviato."
        case .incompatibleDescriptor: return "Il formato HID non corrisponde alla Q6 Max verificata. Nessun comando inviato."
        case .permissionDenied: return "Abilita Monitoraggio input per Keyglow HID Probe."
        case .openFailed: return "macOS ha rifiutato l’apertura della tastiera."
        case .snapshotFailed, .invalidSnapshot: return "Stato iniziale degli indicatori non leggibile. Nessun comando inviato."
        case .writeFailed: return "Invio della richiesta rifiutato dal sistema."
        case .restoreFailed: return "Il ripristino degli indicatori non è confermato. Ricollega la tastiera prima di riprovare."
        case .resultSaveFailed: return "Impossibile salvare il risultato diagnostico privato."
        default: return "Risposta non valida: la prova non conferma il canale di ritorno."
        }
    }
}

enum ProbeWire {
    static let interval: TimeInterval = 0.080
    static let duration: TimeInterval = 15
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x1021 : crc &<< 1 }
        }
        return crc
    }
    static func challenge(nonce: [UInt8]) throws -> [UInt8] {
        guard nonce.count == 4 else { throw ProbeFailure.invalidNonce }
        var bytes: [UInt8] = [0x4b, 0x50, 0x52, 0x42, 1, 1] + nonce + [0]
        let crc = crc16(bytes); bytes += [UInt8(crc >> 8), UInt8(crc & 0xff)]
        return bytes
    }
    static func masks(nonce: [UInt8]) throws -> [UInt8] {
        var result: [UInt8] = [0], clock: UInt8 = 4
        for byte in try challenge(nonce: nonce) {
            for shift in stride(from: 6, through: 0, by: -2) {
                result.append(clock | ((byte >> shift) & 3)); clock ^= 4
            }
        }
        return result
    }
}

/// Retains only diagnostic nibbles from otherwise empty reports. Key bytes are
/// inspected in place and discarded, never copied into the response or result.
struct ProbeDecoder {
    private let nonce: [UInt8]
    private var packet: [UInt8] = []
    private var highNibble: UInt8 = 0
    private(set) var symbols = 0
    private(set) var idleReports = 0
    private(set) var ignoredReports = 0
    private(set) var nonceMatched = false
    private(set) var crcMatched = false
    private(set) var complete = false

    init(nonce: [UInt8]) throws {
        guard nonce.count == 4 else { throw ProbeFailure.invalidNonce }
        self.nonce = nonce
    }

    mutating func accept(reportID: UInt32, bytes: UnsafeBufferPointer<UInt8>, requestComplete: Bool) throws {
        guard [UInt32(1), 4].contains(reportID) else { ignoredReports += 1; return }
        let expectedCount = reportID == 1 ? 8 : 20
        let offset: Int
        if bytes.count == expectedCount { offset = 0 }
        else if bytes.count == expectedCount + 1, bytes[0] == UInt8(reportID) { offset = 1 }
        else { throw ProbeFailure.malformedInput }
        if reportID == 4 {
            guard bytes[offset...].allSatisfy({ $0 == 0 }) else { throw ProbeFailure.inputActivity }
            idleReports += 1
            return
        }
        guard bytes[offset] == 0, bytes[(offset + 2)...].allSatisfy({ $0 == 0 }) else { throw ProbeFailure.inputActivity }
        idleReports += 1
        let symbol = bytes[offset + 1]
        if symbol == 0 { return }
        guard requestComplete else { throw ProbeFailure.responseBeforeRequest }
        guard !complete, symbols < 26, symbol & 0xf0 == (symbols % 2 == 0 ? 0x80 : 0x90) else {
            throw ProbeFailure.unexpectedMarker
        }
        if symbols % 2 == 0 { highNibble = (symbol & 15) << 4 }
        else { packet.append(highNibble | (symbol & 15)); highNibble = 0 }
        symbols += 1
        guard symbols == 26 else { return }
        guard Array(packet.prefix(6)) == [0x4b, 0x50, 0x41, 0x4b, 1, 0], packet[10] == 0 else { throw ProbeFailure.wrongResponse }
        nonceMatched = Array(packet[6..<10]) == nonce
        crcMatched = ProbeWire.crc16(Array(packet.prefix(11))) == (UInt16(packet[11]) << 8 | UInt16(packet[12]))
        guard nonceMatched else { throw ProbeFailure.wrongNonce }
        guard crcMatched else { throw ProbeFailure.wrongCRC }
        complete = true
        packet.removeAll(keepingCapacity: false)
    }
}

struct ProbeTransportFailure: Codable, Equatable, Sendable {
    let stage: String
    let code: Int32
}

struct ProbeResult: Encodable, Sendable {
    let schema = 1
    var status = "not_started"
    var challengeReportsSubmitted = 0
    var responseSymbols = 0
    var idleKeyboardReports = 0
    var ignoredReports = 0
    var nonceMatched = false
    var crcMatched = false
    var restorationAttempted = false
    var restorationAccepted = false
    var inputActivityDetected = false
    var durationMilliseconds = 0
    var transportFailures: [ProbeTransportFailure] = []
    var requestedPauseMilliseconds = 80
    var challengeStartElapsedMilliseconds: Int?
    var challengeEndElapsedMilliseconds: Int?
    var meanWriteDurationMilliseconds: Double?
    var maxWriteDurationMilliseconds: Double?
    var firstResponseElapsedMilliseconds: Int?
    var lastResponseElapsedMilliseconds: Int?
    var roundTripMilliseconds: Int?
}
