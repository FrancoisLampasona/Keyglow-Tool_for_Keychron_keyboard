// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A dotted release number such as "0.11.1" or the tag "v0.12.0-beta.2".
/// A version with a suffix sorts before the same number without one.
struct AppVersion: Comparable, Equatable, Sendable {
    let numbers: [Int]
    let suffix: String
    init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = parts.first, !core.isEmpty else { return nil }
        let fields = core.split(separator: ".", omittingEmptySubsequences: false)
        var parsed = [Int]()
        for field in fields {
            guard !field.isEmpty, field.count <= 9, field.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(field) else { return nil }
            parsed.append(number)
        }
        guard (1...4).contains(parsed.count) else { return nil }
        while parsed.count > 1, parsed.last == 0 { parsed.removeLast() }
        numbers = parsed; suffix = parts.count > 1 ? String(parts[1]) : ""
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let a = index < lhs.numbers.count ? lhs.numbers[index] : 0, b = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if a != b { return a < b }
        }
        if lhs.suffix.isEmpty != rhs.suffix.isEmpty { return !lhs.suffix.isEmpty }
        return lhs.suffix.compare(rhs.suffix, options: .numeric) == .orderedAscending
    }
}

/// On-demand update check against the project's public GitHub releases.
/// Nothing runs in the background, nothing is downloaded or installed, and the
/// request carries no identifier, account, device or usage information.
enum UpdateCheck {
    static let repository = "FrancoisLampasona/Keyglow-Tool_for_Keychron_keyboard"
    static let releasesAPI = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

    struct Release: Equatable, Sendable { let version: AppVersion; let tag: String; let page: URL; let prerelease: Bool }
    enum Outcome: Equatable, Sendable {
        case upToDate(current: String)
        case available(Release)
        case noRelease
    }
    enum Failure: Error, Equatable { case network(String), status(Int), malformed, currentVersion }

    /// The newest published release in a GitHub "list releases" response.
    /// Drafts, unparsable tags and links outside this repository's release pages are ignored.
    static func newestRelease(in data: Data) throws -> Release? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.malformed }
        let prefix = "/\(repository)/releases/"
        return list.compactMap { item -> Release? in
            guard item["draft"] as? Bool != true, let tag = item["tag_name"] as? String, let version = AppVersion(tag),
                  let link = item["html_url"] as? String, let page = URL(string: link), page.scheme == "https",
                  page.host == "github.com", page.path.hasPrefix(prefix), page.query == nil, page.fragment == nil else { return nil }
            return Release(version: version, tag: tag, page: page, prerelease: item["prerelease"] as? Bool == true)
        }.max { $0.version < $1.version }
    }
    static func outcome(current: String, releases data: Data) throws -> Outcome {
        guard let installed = AppVersion(current) else { throw Failure.currentVersion }
        guard let newest = try newestRelease(in: data) else { return .noRelease }
        return newest.version > installed ? .available(newest) : .upToDate(current: current)
    }
    static var request: URLRequest {
        var request = URLRequest(url: releasesAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub requires a User-Agent: a fixed product name, no version or machine data.
        request.setValue("Keyglow", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }
    /// One request, started only by the user's menu action.
    static func check(current: String) async -> Result<Outcome, Failure> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .failure(.malformed) }
            guard status == 200 else { return .failure(.status(status)) }
            guard data.count <= 2_000_000 else { return .failure(.malformed) }
            return Result { try outcome(current: current, releases: data) }.mapError { $0 as? Failure ?? .malformed }
        } catch { return .failure(.network(error.localizedDescription)) }
    }
}
