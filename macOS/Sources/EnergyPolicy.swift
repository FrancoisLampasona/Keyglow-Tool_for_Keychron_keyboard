import Foundation

/// Values supported by the existing Keychron timeout command; zero is not “never”.
enum EnergyPolicy {
    static let reactiveMinutes = 1092
    static let balancedMinutes = 120
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60, remainder = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }
}

struct FirmwareBuildInfo: Decodable, Sendable {
    let buildTimestamp: String
    let capabilities: [String]?
    static let bundled: FirmwareBuildInfo? = {
        guard let url = Bundle.main.url(forResource: "firmware-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FirmwareBuildInfo.self, from: data)
    }()
    func matches(_ version: String) -> Bool {
        version == "v1.1.1 \(buildTimestamp)" || version == "1.1.1 \(buildTimestamp)"
    }
    func supportsDirectRGB(_ version: String) -> Bool {
        matches(version) && capabilities?.contains("rgb-ble-v3-direct") == true &&
            capabilities?.contains("rgb-ble-persistent") == true
    }
}
