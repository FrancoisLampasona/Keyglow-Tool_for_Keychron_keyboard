// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main @MainActor struct UpdateCheckTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func v(_ text: String) -> AppVersion { AppVersion(text)! }
    private static func releases(_ items: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: items) }
    private static func item(_ tag: String, draft: Bool = false, prerelease: Bool = true, url: String? = nil) -> [String: Any] {
        ["tag_name": tag, "draft": draft, "prerelease": prerelease,
         "html_url": url ?? "https://github.com/\(UpdateCheck.repository)/releases/tag/\(tag)"]
    }
    static func main() {
        // Version comparison. No network request is made by this suite.
        expect(v("0.11.1") == v("v0.11.1") && v(" V0.11.1\n") == v("0.11.1"), "the tag prefix and whitespace are ignored")
        expect(v("0.12.0") > v("0.11.1") && v("0.11.10") > v("0.11.9") && v("1.0") > v("0.99.99"), "fields compare as numbers, not text")
        expect(v("0.12") == v("0.12.0") && v("0.12.0.0") == v("0.12") && v("0.12.1") > v("0.12"), "missing fields count as zero")
        expect(v("0.12.0-beta.1") < v("0.12.0") && v("0.12.0-beta.1") > v("0.11.9") && v("0.12.0-beta.2") < v("0.12.0-beta.10"), "a suffix sorts before the final number, and numerically")
        expect(!(v("0.11.1") < v("0.11.1")) && !(v("0.11.1") > v("0.11.1")), "equal versions are neither newer nor older")
        for bad in ["", "v", "abc", "1..2", "1.2.x", "-1.2", "1.2.3.4.5", "1.2 3", "１.２", "9999999999.1", ".1", "1."] {
            expect(AppVersion(bad) == nil, "rejects malformed version \(bad)")
        }

        // The real repository publishes prereleases only: they must be considered.
        let published = releases([item("v0.10.1"), item("v0.11.1"), item("v0.11.0"), item("v0.7.0")])
        expect((try? UpdateCheck.outcome(current: "0.11.1", releases: published)) == .upToDate(current: "0.11.1"), "the installed newest release is up to date")
        expect((try? UpdateCheck.outcome(current: "0.12.0", releases: published)) == .upToDate(current: "0.12.0"), "a local build newer than any release is not offered a downgrade")
        if case .available(let release)? = try? UpdateCheck.outcome(current: "0.11.0", releases: published) {
            expect(release.tag == "v0.11.1" && release.prerelease && release.page.absoluteString == "https://github.com/\(UpdateCheck.repository)/releases/tag/v0.11.1", "the newest release is offered with its page, whatever the list order")
        } else { expect(false, "an older install finds the newer release") }
        expect((try? UpdateCheck.outcome(current: "0.11.1", releases: releases([]))) == .noRelease, "no published release is reported as such")
        expect((try? UpdateCheck.outcome(current: "0.11.1", releases: releases([item("v0.13.0", draft: true), item("nightly")]))) == .noRelease, "drafts and unversioned tags are ignored")
        let hostile = releases([item("v9.0.0", url: "https://example.com/\(UpdateCheck.repository)/releases/tag/v9.0.0"),
                                item("v9.1.0", url: "http://github.com/\(UpdateCheck.repository)/releases/tag/v9.1.0"),
                                item("v9.2.0", url: "https://github.com/someone/else/releases/tag/v9.2.0"),
                                item("v9.3.0", url: "https://github.com/\(UpdateCheck.repository)/releases/tag/v9.3.0?next=https://example.com"),
                                item("v9.4.0", url: "file:///Applications"), item("v0.11.1")])
        expect((try? UpdateCheck.outcome(current: "0.11.1", releases: hostile)) == .upToDate(current: "0.11.1"), "only https pages of this repository's releases are ever offered")
        var mixed = [item("v0.12.0", prerelease: false)]; mixed.append(["tag_name": 12, "html_url": NSNull()]); mixed.append(["unexpected": true])
        if case .available(let release)? = try? UpdateCheck.outcome(current: "0.11.1", releases: releases(mixed)) {
            expect(release.tag == "v0.12.0" && !release.prerelease, "entries with wrong types are skipped, valid ones kept")
        } else { expect(false, "a valid entry among malformed ones is found") }
        for body in ["", "not json", "{\"message\":\"Not Found\"}", "[1,2,3]", "null"] {
            do { _ = try UpdateCheck.outcome(current: "0.11.1", releases: Data(body.utf8)); expect(false, "malformed response accepted: \(body)") }
            catch { expect(error as? UpdateCheck.Failure == .malformed, "a response that is not a release list is an error: \(body)") }
        }
        do { _ = try UpdateCheck.outcome(current: "dev", releases: published); expect(false, "unknown installed version accepted") }
        catch { expect(error as? UpdateCheck.Failure == .currentVersion, "an unreadable installed version is reported, not guessed") }

        // The request: one fixed public URL, no personal or machine data.
        let request = UpdateCheck.request
        expect(request.url?.absoluteString == "https://api.github.com/repos/\(UpdateCheck.repository)/releases?per_page=20" && request.httpMethod == "GET" && request.httpBody == nil, "a plain GET of the public release list")
        expect(request.allHTTPHeaderFields == ["Accept": "application/vnd.github+json", "User-Agent": "Keyglow"], "only Accept and a fixed product name are sent")
        expect(!request.httpShouldHandleCookies, "no cookies are sent or stored")
        let user = NSUserName(), host = ProcessInfo.processInfo.hostName
        let sent = (request.url?.absoluteString ?? "") + (request.allHTTPHeaderFields ?? [:]).map { $0.key + $0.value }.joined()
        expect(!sent.contains(user) && !sent.contains(host), "the request names neither the user nor this Mac")
        print("Update check: \(checks) checks passed (version rules and response parsing only; no network request).")
    }
}
