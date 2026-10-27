import Foundation
import Darwin

enum ProbeResultStore {
    static func save<T: Encodable>(_ result: T, to url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw ProbeFailure.resultSaveFailed }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ProbeFailure.resultSaveFailed }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { try? file.close(); throw ProbeFailure.resultSaveFailed }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try file.write(contentsOf: encoder.encode(result))
        try file.close()
    }
}
