import Foundation

/// A session-scoped VIA client. Read and write calls are synchronous and belong on
/// the same background thread as the exchange. No writes occur in readSnapshot().
final class VIAClient {
    private let exchange: any VIAExchange
    private let productID: Int
    private var hasRead = false

    init(exchange: any VIAExchange, productID: Int) { self.exchange = exchange; self.productID = productID }

    private func request(_ bytes: [UInt8]) throws -> [UInt8] {
        let packet = try VIAProtocol.packet(bytes)
        let response = try exchange.exchange(packet)
        try VIAProtocol.checkResponse(response, request: packet)
        return response
    }
    private func chunk(command: UInt8, offset: Int, count: Int, bytes: [UInt8] = []) throws -> [UInt8] {
        let packet = try VIAProtocol.chunkRequest(command: command, offset: offset, count: count, bytes: bytes)
        let response = try exchange.exchange(packet)
        try VIAProtocol.checkResponse(response, request: packet)
        return response
    }
    private func readBuffer(command: UInt8, length: Int) throws -> [UInt8] {
        var result = [UInt8]()
        for offset in stride(from: 0, to: length, by: 28) {
            let count = min(28, length - offset)
            let response = try chunk(command: command, offset: offset, count: count)
            result += response[4..<(4 + count)]
        }
        return result
    }
    private func readLighting() throws -> VIALighting {
        let b = try request([0x08, 3, 1])[3]
        let e = try request([0x08, 3, 2])[3]
        let s = try request([0x08, 3, 3])[3]
        let c = try request([0x08, 3, 4])
        return VIALighting(brightness: b, effect: e, speed: s, hue: c[3], saturation: c[4])
    }
    private func optional<T>(_ name: String, warnings: inout [String], _ read: () throws -> T) throws -> T? {
        do { return try read() }
        catch VIAError.unsupported { warnings.append("\(name) non esposto da questo firmware."); return nil }
        catch VIAError.failedCommand { warnings.append("\(name) rifiutato dal firmware; funzione non abilitata."); return nil }
    }

    func readSnapshot() throws -> VIASnapshot {
        guard [0x0860, 0x0861].contains(productID) else { throw VIAError.incompatibleDevice }
        let version = VIAProtocol.uint16(try request([1]), 1)
        guard version == VIAProtocol.supportedVersion else { throw VIAError.invalid("Versione VIA \(version) non verificata: questa build supporta il protocollo 12 della Q6 Max. Nessuna impostazione modificata.") }
        let layerCount = Int(try request([0x11])[1])
        guard layerCount == 4 else { throw VIAError.invalid("Il firmware riporta \(layerCount) layer; il profilo Q6 Max verificato ne prevede 4. Nessuna impostazione modificata.") }
        let keymap = try readBuffer(command: 0x12, length: layerCount * 6 * 20 * 2)
        let layers = (0..<layerCount).map { layer in
            (0..<120).map { VIAProtocol.uint16(keymap, (layer * 120 + $0) * 2) }
        }
        var encoders = [[UInt16]]()
        for layer in 0..<layerCount {
            let ccw = try request([0x14, UInt8(layer), 0, 0])
            let cw = try request([0x14, UInt8(layer), 0, 1])
            encoders.append([VIAProtocol.uint16(ccw, 4), VIAProtocol.uint16(cw, 4)])
        }
        let macroCount = Int(try request([0x0C])[1])
        let macroCapacity = Int(VIAProtocol.uint16(try request([0x0D]), 1))
        guard (1...64).contains(macroCount), (macroCount + 1...8192).contains(macroCapacity) else { throw VIAError.invalid("Memoria macro non compatibile con il profilo supportato.") }
        let buffer = try readBuffer(command: 0x0E, length: macroCapacity)
        let lighting = try readLighting()
        var warnings = [String]()
        let firmware = try optional("Versione firmware", warnings: &warnings) {
            let bytes = try request([0xA1]).dropFirst().prefix(while: { $0 != 0 })
            guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw VIAError.malformedResponse }
            return String(decoding: bytes, as: UTF8.self)
        } ?? "Non disponibile"
        let features: UInt16 = try optional("Funzioni Keychron", warnings: &warnings) {
            let response = try request([0xA2])
            guard response[1] == 0 else { throw VIAError.malformedResponse }
            return UInt16(response[2]) | (UInt16(response[3]) << 8)
        } ?? 0
        let misc: UInt8 = try optional("Opzioni avanzate", warnings: &warnings) {
            let response = try request([0xA7, 1])
            guard VIAProtocol.little16(response, 3) == 2 else { throw VIAError.unsupported(0xA7) }
            return response[5]
        } ?? 0
        var custom: VIACustomRGB?
        if features & 0x80 != 0 {
            custom = try optional("RGB per tasto e mix", warnings: &warnings) { try readCustomRGB() }
        }
        var wireless: VIAWirelessSettings?
        if misc & 0x10 != 0 {
            wireless = try optional("Risparmio energetico", warnings: &warnings) {
                let response = try request([0xA7, 0x0B])
                return VIAWirelessSettings(backlightTimeoutSeconds: VIAProtocol.little16(response, 3), sleepTimeoutSeconds: VIAProtocol.little16(response, 5))
            }
        }
        var nkro: Bool?, nkroCanSet = false
        if misc & 0x80 != 0 {
            let flag = try optional("NKRO", warnings: &warnings) { try request([0xA7, 0x12])[3] }
            if let flag { nkro = flag & 1 != 0; nkroCanSet = flag & 2 != 0 && flag & 4 == 0 }
        }
        let snapshot = VIASnapshot(layers: layers, encoders: encoders, macroBuffer: buffer, macroCount: macroCount, macroCapacity: macroCapacity, lighting: lighting, firmwareVersion: firmware, protocolVersion: version, productID: productID, featureFlags: features, miscCapabilities: misc, customRGB: custom, wireless: wireless, nkro: nkro, nkroCanSet: nkroCanSet, warnings: warnings)
        try validate(snapshot, allowOpaqueMacro: true)
        hasRead = true
        return snapshot
    }

    private func readCustomRGB() throws -> VIACustomRGB {
        let version = try request([0xA8, 1])
        guard VIAProtocol.little16(version, 3) == 1 else { throw VIAError.unsupported(0xA8) }
        let count = Int(try request([0xA8, 5])[3])
        let expectedLEDs = productID == 0x0861 ? 109 : 108
        guard count == expectedLEDs else { throw VIAError.invalid("Numero LED non compatibile con la variante Q6 Max rilevata.") }
        var indices = [[UInt8]]()
        for row in 0..<6 {
            let response = try request([0xA8, 6, UInt8(row), 0xFF, 0xFF, 0x0F])
            let values = Array(response[3..<23])
            guard values.allSatisfy({ $0 == 255 || Int($0) < count }) else { throw VIAError.malformedResponse }
            indices.append(values)
        }
        let type = try request([0xA8, 7])[3]
        var colors = [VIAHSV]()
        for start in stride(from: 0, to: count, by: 9) {
            let n = min(9, count - start), response = try request([0xA8, 9, UInt8(start), UInt8(min(9, count - start))])
            for i in 0..<n { colors.append(VIAHSV(hue: response[3+i*3], saturation: response[4+i*3], value: response[5+i*3])) }
        }
        let info = try request([0xA8, 0x0B])
        let regionCount = Int(info[3]), slots = Int(info[4])
        guard (1...16).contains(regionCount), (1...32).contains(slots) else { throw VIAError.malformedResponse }
        var regions = [UInt8]()
        for start in stride(from: 0, to: count, by: 29) {
            let n = min(29, count-start), response = try request([0xA8, 0x0C, UInt8(start), UInt8(min(29, count-start))])
            regions += response[3..<(3+n)]
        }
        var effects = [[VIAMixedEffect]]()
        for region in 0..<regionCount {
            var list = [VIAMixedEffect]()
            for start in stride(from: 0, to: slots, by: 3) {
                let n = min(3, slots-start), response = try request([0xA8, 0x0E, UInt8(region), UInt8(start), UInt8(min(3, slots-start))])
                for i in 0..<n {
                    let p = 3 + i*8
                    list.append(VIAMixedEffect(effect: response[p], hue: response[p+1], saturation: response[p+2], speed: response[p+3], durationMilliseconds: VIAProtocol.little32(response, p+4)))
                }
            }
            effects.append(list)
        }
        let indicators = try request([0xA8, 3])
        return VIACustomRGB(type: type, colors: colors, ledIndices: indices, regions: regions, effects: effects, supportedIndicatorsMask: indicators[3], indicatorsDisabledMask: indicators[4], indicatorColor: VIAHSV(hue: indicators[5], saturation: indicators[6], value: indicators[7]))
    }

    /// Preflight validates the entire draft and re-reads the keyboard before the first
    /// setting write. Only differences are written. Non-atomic hardware writes are
    /// reported honestly; on failure no automatic rollback can overwrite newer work.
    func applyChanges(baseline: VIASnapshot, desired: VIASnapshot, allowOpaqueMacroRestore: Bool = false) throws -> VIASnapshot {
        try validate(baseline, allowOpaqueMacro: true)
        try validate(desired, allowOpaqueMacro: allowOpaqueMacroRestore || desired.macroBuffer == baseline.macroBuffer)
        guard baseline.productID == productID, desired.productID == productID,
              baseline.protocolVersion == desired.protocolVersion,
              baseline.rows == desired.rows, baseline.cols == desired.cols,
              baseline.macroCount == desired.macroCount, baseline.macroCapacity == desired.macroCapacity,
              baseline.featureFlags == desired.featureFlags, baseline.miscCapabilities == desired.miscCapabilities,
              baseline.nkroCanSet == desired.nkroCanSet else { throw VIAError.invalid("La bozza non corrisponde alla variante e alle capacità della tastiera letta.") }
        guard (baseline.customRGB == nil) == (desired.customRGB == nil), (baseline.wireless == nil) == (desired.wireless == nil), (baseline.nkro == nil) == (desired.nkro == nil) else { throw VIAError.invalid("La bozza richiede funzioni non lette dalla tastiera.") }
        if let a=baseline.customRGB, let b=desired.customRGB {
            guard a.ledIndices == b.ledIndices, a.colors.count == b.colors.count, a.effects.count == b.effects.count,
                  zip(a.effects,b.effects).allSatisfy({ $0.count == $1.count }), a.supportedIndicatorsMask == b.supportedIndicatorsMask else { throw VIAError.invalid("Mappa LED o dimensioni mix non corrispondenti alla tastiera.") }
        }
        if desired.nkro != baseline.nkro && !baseline.nkroCanSet { throw VIAError.invalid("Il firmware gestisce NKRO automaticamente e non consente questa modifica.") }
        let current = try readSnapshot()
        guard hasRead, sameSettings(current, baseline) else { throw VIAError.conflict }
        var attemptedWrite = false
        func write(_ bytes: [UInt8]) throws { attemptedWrite = true; _ = try request(bytes) }
        do {
            for layer in 0..<4 {
                for index in 0..<120 where desired.layers[layer][index] != baseline.layers[layer][index] {
                    let code = desired.layers[layer][index]
                    try write([0x05, UInt8(layer), UInt8(index/20), UInt8(index%20), UInt8(code>>8), UInt8(code&255)])
                }
                for direction in 0..<2 where desired.encoders[layer][direction] != baseline.encoders[layer][direction] {
                    let code = desired.encoders[layer][direction]
                    try write([0x15, UInt8(layer), 0, UInt8(direction), UInt8(code>>8), UInt8(code&255)])
                }
            }
            if desired.macroBuffer != baseline.macroBuffer {
                // QMK suppresses macro playback while its final byte is nonzero.
                attemptedWrite = true
                _ = try chunk(command: 0x0F, offset: desired.macroCapacity-1, count: 1, bytes: [0xFF])
                for offset in stride(from: 0, to: desired.macroCapacity-1, by: 28) {
                    let n = min(28, desired.macroCapacity-1-offset)
                    _ = try chunk(command: 0x0F, offset: offset, count: n, bytes: Array(desired.macroBuffer[offset..<(offset+n)]))
                }
                // Verify content before removing the playback guard.
                let staged = try readBuffer(command: 0x0E, length: desired.macroCapacity)
                guard Array(staged.dropLast()) == Array(desired.macroBuffer.dropLast()), staged.last == 0xFF else { throw VIAError.readback("macro in scrittura") }
                _ = try chunk(command: 0x0F, offset: desired.macroCapacity-1, count: 1, bytes: [desired.macroBuffer.last ?? 0])
            }
            let a=baseline.lighting, b=desired.lighting
            let changes: [(UInt8,[UInt8],Bool)] = [(1,[b.brightness],a.brightness != b.brightness), (2,[b.effect],a.effect != b.effect), (3,[b.speed],a.speed != b.speed), (4,[b.hue,b.saturation],a.hue != b.hue || a.saturation != b.saturation || a.effect != b.effect)]
            if changes.contains(where: { $0.2 }) {
                // Clear stale firmware property mask before per-property saves.
                try write([0x09,3])
                for (property,value,changed) in changes where changed {
                    try write([0x07,3,property] + value)
                    try write([0x09,3])
                }
            }
            if let a=baseline.customRGB, let b=desired.customRGB, a != b {
                if a.type != b.type { try write([0xA8,8,b.type]) }
                for start in stride(from:0,to:b.colors.count,by:9) {
                    let end=min(start+9,b.colors.count)
                    if a.colors[start..<end] != b.colors[start..<end] {
                        let values=b.colors[start..<end].flatMap { [$0.hue,$0.saturation,$0.value] }
                        try write([0xA8,10,UInt8(start),UInt8(end-start)] + values)
                    }
                }
                for start in stride(from:0,to:b.regions.count,by:28) {
                    let end=min(start+28,b.regions.count)
                    if a.regions[start..<end] != b.regions[start..<end] { try write([0xA8,13,UInt8(start),UInt8(end-start)] + Array(b.regions[start..<end])) }
                }
                for region in b.effects.indices {
                    for start in stride(from:0,to:b.effects[region].count,by:3) {
                        let end=min(start+3,b.effects[region].count)
                        if a.effects[region][start..<end] != b.effects[region][start..<end] {
                            let values=b.effects[region][start..<end].flatMap { [$0.effect,$0.hue,$0.saturation,$0.speed] + VIAProtocol.littleBytes($0.durationMilliseconds) }
                            try write([0xA8,15,UInt8(region),UInt8(start),UInt8(end-start)] + values)
                        }
                    }
                }
                if a.indicatorsDisabledMask != b.indicatorsDisabledMask || a.indicatorColor != b.indicatorColor {
                    try write([0xA8,4,b.indicatorsDisabledMask,b.indicatorColor.hue,b.indicatorColor.saturation,b.indicatorColor.value])
                }
                try write([0xA8,2])
            }
            if let a=baseline.wireless, let b=desired.wireless, a != b {
                try write([0xA7,0x0C,UInt8(b.backlightTimeoutSeconds&255),UInt8(b.backlightTimeoutSeconds>>8),UInt8(b.sleepTimeoutSeconds&255),UInt8(b.sleepTimeoutSeconds>>8)])
            }
            if let b=desired.nkro, b != baseline.nkro { try write([0xA7,0x13,b ? 1:0]) }
            let verified = try readSnapshot()
            guard sameSettings(verified, desired, brightnessTolerance:2) else { throw VIAError.readback("configurazione") }
            return verified
        } catch {
            if attemptedWrite { throw VIAError.partialWrite(error.localizedDescription) }
            throw error
        }
    }

    /// Matrix reads may be suppressed by firmware compiled without VIA_INSECURE.
    /// A zero result therefore cannot prove that no physical keys are pressed.
    func readMatrix() throws -> [[Bool]] {
        guard hasRead else { throw VIAError.invalid("Leggi prima la configurazione della tastiera.") }
        let response = try request([0x02,0x03,0])
        return (0..<6).map { row in
            let p=3+row*3
            let mask=(UInt32(response[p])<<16)|(UInt32(response[p+1])<<8)|UInt32(response[p+2])
            return (0..<20).map { mask & (1<<$0) != 0 }
        }
    }

    private func validate(_ snapshot: VIASnapshot, allowOpaqueMacro: Bool) throws {
        guard [0x0860,0x0861].contains(snapshot.productID), snapshot.protocolVersion == 12,
              snapshot.rows == 6, snapshot.cols == 20, snapshot.layers.count == 4,
              snapshot.layers.allSatisfy({$0.count == 120}), snapshot.encoders.count == 4,
              snapshot.encoders.allSatisfy({$0.count == 2}), (1...64).contains(snapshot.macroCount),
              (snapshot.macroCount+1...8192).contains(snapshot.macroCapacity), snapshot.macroBuffer.count == snapshot.macroCapacity else { throw VIAError.invalid("Configurazione incompleta o dimensioni non compatibili con Q6 Max.") }
        if !allowOpaqueMacro { _ = try VIAMacroCodec.decode(snapshot.macroBuffer, count:snapshot.macroCount) }
        guard snapshot.lighting.effect <= (snapshot.customRGB == nil ? 22:24) else { throw VIAError.invalid("Effetto RGB non supportato dalle capacità lette.") }
        if let custom=snapshot.customRGB {
            let count=snapshot.productID == 0x0861 ? 109:108
            guard custom.type < 5, custom.colors.count == count, custom.regions.count == count,
                  custom.ledIndices.count == 6, custom.ledIndices.allSatisfy({$0.count == 20 && $0.allSatisfy({$0 == 255 || Int($0)<count})}),
                  (1...16).contains(custom.effects.count), custom.effects.allSatisfy({(1...32).contains($0.count)}),
                  custom.regions.allSatisfy({Int($0)<custom.effects.count}),
                  custom.effects.flatMap({$0}).allSatisfy({$0.effect < 24}), custom.indicatorColor.value >= 128,
                  custom.indicatorsDisabledMask & ~custom.supportedIndicatorsMask == 0 else { throw VIAError.invalid("Configurazione RGB per tasto o mix non valida.") }
        }
        if let wireless=snapshot.wireless {
            guard wireless.backlightTimeoutSeconds >= 5, wireless.sleepTimeoutSeconds >= 60 else { throw VIAError.invalid("Il timeout luci deve essere almeno 5 secondi e lo standby almeno 60 secondi.") }
        }
    }
    private func sameSettings(_ a:VIASnapshot,_ b:VIASnapshot,brightnessTolerance:Int=0)->Bool {
        var lighting=a.lighting
        if abs(Int(a.lighting.brightness)-Int(b.lighting.brightness)) <= brightnessTolerance { lighting.brightness=b.lighting.brightness }
        return a.productID == b.productID && a.protocolVersion == b.protocolVersion && a.layers == b.layers && a.encoders == b.encoders && a.macroBuffer == b.macroBuffer && a.macroCount == b.macroCount && a.macroCapacity == b.macroCapacity && lighting == b.lighting && a.customRGB == b.customRGB && a.wireless == b.wireless && a.nkro == b.nkro && a.featureFlags == b.featureFlags && a.miscCapabilities == b.miscCapabilities && a.nkroCanSet == b.nkroCanSet
    }
}
