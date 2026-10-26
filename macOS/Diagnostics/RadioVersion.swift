import Foundation

@main
private enum RadioVersionCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["--read"] || arguments == ["--self-test"] else {
            print("""
            Uso: scripts/read-radio-version.sh --read | --self-test | --build-only
            --read: una query informativa GET_DFU_VER 0x60 via USB Q6 Max ISO; timeout 3 s, nessun retry.
            --self-test: solo parser e frame sintetici, senza enumerare dispositivi.
            Non modifica configurazione/firmware e non avvia handshake o aggiornamenti.
            La query usa un report Output HID e può risvegliare il modulo radio.
            macOS può negare accesso alla CLI: nessuna richiesta/reset automatico dei permessi.
            """)
            exit(arguments.isEmpty || arguments == ["--help"] ? 0 : 64)
        }
        var json: [String: Any] = ["diagnostic": "q6-max-iso-radio-version", "configurationWrites": false,
                                  "firmwareWrites": false, "handshakeRequested": false, "retries": 0,
                                  "outputRequestsAttempted": 0, "hardwareAccessAttempted": false]
        var exitCode: Int32 = 0
        do {
            if arguments == ["--self-test"] {
                json["testsPassed"] = try RadioVersionReader.selfTestOffline()
                json["status"] = "offline_tests_passed"
            } else {
                json["hardwareAccessAttempted"] = true
                let result = try RadioVersionReader.readUSB()
                json["status"] = "read_succeeded"
                json["outputRequestsAttempted"] = 1
                json["radio"] = ["moduleModel": result.moduleModel, "firmwareVersion": result.firmwareVersion,
                    "hardwareVersion": result.hardwareVersion,
                    "rawVersionFields": ["modelHex": result.rawModelHex, "firmwareHex": result.rawFirmwareHex,
                                         "hardwareHex": result.rawHardwareHex]] as [String: Any]
                if result.launcherFirmwareVersion != result.firmwareVersion {
                    json["launcherNineByteFirmwareVersion"] = result.launcherFirmwareVersion
                }
                json["responseFragments"] = result.responseFragments
                json["device"] = ["vendorID": "0x3434", "productID": "0x0861", "transport": "USB", "usagePage": "0xFF60", "usage": "0x61"]
            }
        } catch {
            json["status"] = "failed"; json["error"] = error.localizedDescription; exitCode = 2
            if let failure = error as? RadioVersionReadError { json["outputRequestsAttempted"] = failure.outputRequestsAttempted }
            json["macOSAccessNote"] = "La CLI può non avere gli stessi permessi dell'app Tastiera. Nessun permesso è richiesto o reimpostato automaticamente."
        }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        exit(exitCode)
    }
}
