// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
@main enum EngineTests {
    static func main() throws {
        precondition(CommandLine.arguments.count == 4)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        process.arguments = [CommandLine.arguments[2]]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        defer { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
        let old = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let package = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let artifact = try FirmwareUpdateArtifact.parse(package, fileName: "build-b.kgfw", isPackage: true)
        let key = try FirmwareOwnerKey(rawRepresentation: Data(1...32))
        var interrupted = false, requests = [UInt8](), copyOperations = 0
        let worker = FirmwareUpdateCoordinator(exchange: { frame, token in
            let request = try BluetoothOTAWire.parseRequest(frame); requests.append(request.operation)
            if request.operation == 6 { copyOperations += 1 }
            let encoded = frame.map { String(format: "%02x", $0) }.joined() + "\n"
            try input.fileHandleForWriting.write(contentsOf: Data(encoded.utf8))
            var line = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte[0] == 10 { break }; line.append(byte)
                precondition(line.count <= 286)
            }
            guard let text = String(data: line, encoding: .utf8), text.count >= 30 else { fatalError("Core bridge ended without a reply") }
            let characters = Array(text); var bytes = [UInt8]()
            for offset in stride(from: 0, to: characters.count, by: 2) { bytes.append(UInt8(String(characters[offset...offset + 1]), radix: 16)!) }
            let reply = try BluetoothOTAWire.parseReply(bytes)
            if request.operation == 2 && reply.result == 0 && !interrupted {
                interrupted = true; throw OTAChannelFailure.disconnected
            }
            return .init(reply: reply, duration: 0, outputReports: 0, receiptSubmitted: true)
        }, loadKey: { $0 == key.keyID ? key : nil }, baseline: { _ in old }, wait: { _, _ in })
        let first = try worker.review(artifact, cancellation: .init())
        let budget = try first.plan.budget(transport: .ledAndReservedByte, retryAllowance: 0)
        print("Actual A→B: \(first.plan.literalBytes) literal bytes, \(first.plan.copyRuns.count) COPY runs, \(budget.exchanges) exchanges, \(budget.writes) LED writes and \(budget.replyReports) response reports.")
        do { _ = try worker.install(first, replace: false, cancellation: .init()); fatalError("Expected injected lost DATA reply") }
        catch OTAChannelFailure.disconnected { }
        precondition(interrupted && !requests.contains(5))
        let resumed = try worker.review(artifact, cancellation: .init())
        let result = try worker.install(resumed, replace: false, cancellation: .init())
        precondition(result.image.sha256 == artifact.manifest.sha256 && result.build == artifact.manifest.build)
        precondition(requests.filter { $0 == 5 }.count == 1 && copyOperations > 0)
        print("Swift coordinator -> real C auth/staging/loader engine: installed A -> lost DATA reply -> resumed B -> authenticated post-boot hash/build PASS. RAM flash and public fixture key only.")
    }
}
