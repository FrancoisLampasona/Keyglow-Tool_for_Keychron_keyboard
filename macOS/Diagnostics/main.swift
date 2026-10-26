import Foundation

// Read-only diagnostic entry point. This target never calls HIDTransport.send.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
    print("""
    Uso: scripts/diagnose-hid.sh [--read-led]

    Senza argomenti: elenca soltanto le Q6 Max Bluetooth compatibili.
    --read-led: tenta esplicitamente anche una lettura del report LED.
    Non scrive report HID, non legge tasti e non richiede permessi macOS.
    """)
    exit(0)
}
guard arguments.isEmpty || arguments == ["--read-led"] else {
    fputs("Argomenti non validi. Usa --help.\n", stderr)
    exit(64)
}

var output: [String: Any] = [
    "diagnostic": "q6-max-bluetooth-hid",
    "readOnly": true,
    "inputCallbacksRegistered": false,
    "outputWritesAttempted": false,
    "readLEDRequested": arguments == ["--read-led"],
]
var exitStatus: Int32 = 0
do {
    let devices = try HIDTransport.enumerate()
    output["devices"] = devices.map { device in
        ["productName": device.productName,
         "productID": String(format: "0x%04X", device.productID),
         "transport": device.transport,
         "supportsExpectedLEDReport": device.supportsExpectedLEDReport] as [String: Any]
    }
    if arguments == ["--read-led"] {
        output["ledMask"] = try HIDTransport.readLEDState()
        output["status"] = "read_succeeded"
    } else {
        output["status"] = "enumeration_only"
    }
} catch {
    output["status"] = "failed"
    output["error"] = error.localizedDescription
    if case HIDTransportError.accessNotGranted = error {
        output["failureStage"] = "macOS_access_preflight"
        output["deviceOpenAttempted"] = false
    }
    exitStatus = 2
}
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
exit(exitStatus)
