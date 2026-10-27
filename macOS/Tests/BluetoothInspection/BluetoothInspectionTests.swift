// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
struct BluetoothInspectionTests {
    static func main() {
        let observed = Data([0x02, 0x34, 0x34, 0x61, 0x08, 0x01, 0x02])
        let identity = BluetoothQ6Identity.parse(observed)!
        precondition(identity.vendor == 0x3434 && identity.product == 0x0861 && identity.version == 0x0201)
        precondition(identity.matches(name: "Keychron Q6 Max", model: "Keychron Q6 Max"))
        precondition(identity.matches(name: " KEYCHRON Q6 MAX ", model: "Keychron Q6 Max"))
        precondition(!identity.matches(name: "Keychron Q6", model: "Keychron Q6 Max"))
        precondition(!identity.matches(name: "Keychron Q6 Max", model: "Keychron Q6 Max Pro"))
        precondition(!identity.matches(name: nil, model: "Keychron Q6 Max"))
        precondition(!identity.matches(name: "Keychron Q6 Max", model: nil))
        for field in [1, 2, 3, 4] {
            var wrong = observed; wrong[field] ^= 1
            precondition(!BluetoothQ6Identity.parse(wrong)!.matches(name: "Keychron Q6 Max", model: "Keychron Q6 Max"))
        }
        for source: UInt8 in [0, 1, 3, 255] {
            var wrong = observed; wrong[0] = source
            precondition(BluetoothQ6Identity.parse(wrong) == nil)
        }
        precondition(BluetoothQ6Identity.parse(observed.dropLast()) == nil)
        precondition(BluetoothQ6Identity.parse(observed + Data([0])) == nil)
        precondition(BluetoothQ6Identity.parse(Data()) == nil)
        precondition(BluetoothQ6Identity.text(Data("0.2.1".utf8)) == "0.2.1")
        precondition(BluetoothQ6Identity.text(Data("Keychron Q6 Max\0".utf8)) == "Keychron Q6 Max")
        precondition(BluetoothQ6Identity.text(Data("Keychron\0Q6 Max".utf8)) == nil)
        precondition(BluetoothQ6Identity.text(Data([0xff, 0xfe])) == nil)
        precondition(BluetoothQ6Identity.text(Data(repeating: 65, count: 65)) == nil)
        precondition(BluetoothQ6Identity.text(Data()) == nil)
        for valid: UInt8 in [0, 84, 100] { precondition(BluetoothQ6Identity.battery(Data([valid])) == Int(valid)) }
        for invalid in [Data(), Data([101]), Data([255]), Data([84, 0])] { precondition(BluetoothQ6Identity.battery(invalid) == nil) }
        print("Bluetooth identity, target, bounded text and battery parsers passed; no manager or hardware connection created")
    }
}
