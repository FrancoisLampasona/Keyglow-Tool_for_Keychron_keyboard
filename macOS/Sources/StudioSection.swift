// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The pages of the main window. Raw values are the historical page numbers:
/// the setup guide's destination and the ⌘1–⌘9 shortcuts depend on them.
enum StudioSection: Int, CaseIterable, Identifiable, Sendable {
    case lighting = 0, keymap, macros, keyTest, profiles, energy, connection, firmware, quickLaunch
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .lighting: "Illuminazione"
        case .keymap: "Mappa dei tasti"
        case .macros: "Macro"
        case .keyTest: "Test tastiera"
        case .profiles: "Profili"
        case .energy: "Energia"
        case .connection: "Connessione"
        case .firmware: "Firmware"
        case .quickLaunch: "Avvio rapido"
        }
    }
    var symbol: String {
        switch self {
        case .lighting: "sun.max"
        case .keymap: "keyboard"
        case .macros: "command"
        case .keyTest: "checkmark.circle"
        case .profiles: "square.stack"
        case .energy: "battery.75percent"
        case .connection: "antenna.radiowaves.left.and.right"
        case .firmware: "cpu"
        case .quickLaunch: "bolt"
        }
    }
    var subtitle: String {
        switch self {
        case .lighting: "La tua Q6 Max, nella sua luce."
        case .keymap: "Ogni tasto, ogni livello. Il layout della tua ISO italiana."
        case .macros: "Sequenze precise, pronte da assegnare a un tasto."
        case .keyTest: "Verifica i tasti ricevuti in questa finestra."
        case .profiles: "Le tue configurazioni, conservate sul Mac."
        case .energy: "Prontezza, autonomia e spegnimento delle luci."
        case .connection: "Dispositivo, accesso e collegamenti."
        case .firmware: "Firmware, verifiche e aggiornamenti."
        case .quickLaunch: "Apri app e siti con una scorciatoia dedicata."
        }
    }
    /// Pages whose draft is applied over USB from the footer.
    var editsDraft: Bool { [.keymap, .macros, .energy].contains(self) }
    /// Pages that only concern this Mac.
    var isLocal: Bool { [.keyTest, .profiles, .quickLaunch].contains(self) }
    /// Device and settings pages use a narrower reading width.
    var usesReadingWidth: Bool { rawValue >= StudioSection.profiles.rawValue }
}
