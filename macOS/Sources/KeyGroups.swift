// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Selection groups for lighting, derived from the physical layout: horizontal
/// blocks come from the gaps between key columns, key roles from keycap
/// appearance, rows from vertical position. No key list is written by hand.
enum KeyGroup: Hashable, Sendable {
    case lettersAndSymbols, modifiers, functionRow, navigation, numpad
    /// Visual row from the top, starting at 0. A tall key belongs to the row where it starts.
    case row(Int)
    var title: String {
        switch self {
        case .lettersAndSymbols: "Lettere e simboli"
        case .modifiers: "Modificatori"
        case .functionRow: "Riga funzione"
        case .navigation: "Navigazione"
        case .numpad: "Tastierino numerico"
        case .row(let index): "Riga \(index + 1)"
        }
    }
}

extension KeyboardDefinition {
    private var litKeys: [PhysicalKey] { keys.filter { $0.ledIndex != nil } }
    private var rowOrigins: [Double] { Array(Set(litKeys.map(\.y))).sorted() }
    /// Horizontal blocks (main, navigation, numpad…) separated by a visible gap.
    /// The top row is left out because its keys are spaced within one block.
    private var blocks: [ClosedRange<Double>] {
        guard let top = rowOrigins.first else { return [] }
        var merged = [ClosedRange<Double>]()
        for key in litKeys.filter({ $0.y > top }).sorted(by: { $0.x < $1.x }) {
            let end = key.x + key.width
            if let last = merged.last, key.x <= last.upperBound + 0.1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, end)
            } else { merged.append(key.x...end) }
        }
        return merged
    }
    private func block(of key: PhysicalKey) -> Int? {
        let center = key.x + key.width / 2
        return blocks.firstIndex { $0.contains(center) }
    }

    var keyGroups: [KeyGroup] {
        [.lettersAndSymbols, .modifiers, .functionRow, .navigation, .numpad] + rowOrigins.indices.map { .row($0) }
    }
    /// Identifiers of the lit keys in a group, in layout order.
    func keyIDs(in group: KeyGroup) -> [String] {
        let origins = rowOrigins, count = blocks.count
        return litKeys.filter { key in
            let zone = block(of: key), top = key.y == origins.first
            switch group {
            case .functionRow: return top && zone == 0
            case .lettersAndSymbols: return !top && zone == 0 && key.appearance != .dark
            case .modifiers: return !top && zone == 0 && key.appearance == .dark
            case .numpad: return count > 1 && zone == count - 1
            // Everything between the main block and the numpad, and any key outside all blocks.
            case .navigation: return zone == nil || (zone! > 0 && zone! < max(1, count - 1))
            case .row(let index): return origins.indices.contains(index) && key.y == origins[index]
            }
        }.map(\.id)
    }
}
