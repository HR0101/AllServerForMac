import Foundation
import Testing
@testable import ArkServer

@Suite(.serialized)
@MainActor
struct AppUpdaterTests {
    @Test func semanticVersions() throws {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.2", "1.10"]
        let versions = try ordered.map { try #require(UpdateVersion($0)) }
        for (a, b) in zip(versions, versions.dropFirst()) { #expect(a < b) }
        #expect(UpdateVersion("v1.2.0") == UpdateVersion("1.2"))
        #expect(UpdateVersion("1.0.0+build.2") == UpdateVersion("1.0.0+build.1"))
        for invalid in ["", "1..2", "1.2.3.4", "1.0.0-", "01.2.3", "1.0.0-01", "1.0.0+", "garbage"] {
            #expect(UpdateVersion(invalid) == nil)
        }
        let current = try #require(UpdateVersion("1.0.0"))
        #expect(try #require(UpdateVersion("1.0.0+2")).isNewer(than: current, currentBuild: 1))
        #expect(!current.isNewer(than: current, currentBuild: 1))
        #expect(!(try #require(UpdateVersion("0.9.0+99"))).isNewer(than: current, currentBuild: 1))
    }

    @Test func checksAndSkipPersistence() async throws {
        let (updater, defaults, session, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
        UpdateMockProtocol.response = (200, releaseJSON(), nil)
        // Automatic detection stops at availability; download requires user action.
        updater.check(manual: false)
        #expect(updater.state == .checking)
        await finish(updater)
        guard case .available(let release) = updater.state else { Issue.record("Expected update"); return }
        #expect(release.downloadURL != nil)
        #expect(updater.lastCheck != nil)
        updater.skip(release)
        #expect(updater.state == .idle)
        updater.check(manual: false)
        await finish(updater)
        #expect(updater.state == .idle)
        updater.check(manual: true)
        await finish(updater)
        #expect(updater.state == .available(release))
        updater.automaticallyChecks = false
        let restored = AppUpdater(defaults: defaults, session: session, version: "1.0", build: "1", presentsWindows: false)
        #expect(!restored.automaticallyChecks)
        #expect(restored.lastCheck != nil)
        UpdateMockProtocol.response = (200, releaseJSON(tag: "v3.0.0"), nil)
        updater.check(manual: false)
        await finish(updater)
        guard case .available(let newer) = updater.state else { Issue.record("New version should not be skipped"); return }
        #expect(newer.tag_name == "v3.0.0")
    }

    @Test func sameAndOlderAreUpToDate() async throws {
        let (updater, defaults, session, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
        for tag in ["v1.0.0", "v0.9.0"] {
            UpdateMockProtocol.response = (200, releaseJSON(tag: tag), nil)
            updater.check(manual: true)
            await finish(updater)
            #expect(updater.state == .upToDate)
        }
        UpdateMockProtocol.response = (404, Data(), nil)
        updater.check(manual: true)
        await finish(updater)
        #expect(updater.state == .noRelease)
    }

    @Test func malformedAndNetworkErrors() async throws {
        let (updater, defaults, session, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
        for response: (Int, Data, Error?) in [
            (200, Data("not JSON".utf8), nil),
            (200, releaseJSON(tag: "nonsense"), nil),
            (403, Data(), nil), (429, Data(), nil), (500, Data(), nil),
            (200, Data(), URLError(.notConnectedToInternet)),
            (200, Data(), URLError(.timedOut))
        ] {
            UpdateMockProtocol.response = response
            updater.check(manual: true)
            await finish(updater)
            guard case .failed = updater.state else { Issue.record("Expected visible manual error"); continue }
            #expect(updater.lastCheck == nil)
            updater.check(manual: false)
            await finish(updater)
            #expect(updater.state == .idle)
        }
    }

    @Test func downloadCancellationRestoresOffer() async throws {
        let (updater, defaults, session, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
        let release = try JSONDecoder().decode(AppRelease.self, from: releaseJSON())
        updater.download(release)
        #expect(updater.state == .downloading(release))
        updater.check(manual: true)
        #expect(updater.state == .downloading(release))
        updater.cancelDownload()
        #expect(updater.state == .available(release))
        try await Task.sleep(for: .milliseconds(50))
        #expect(updater.state == .available(release))
        #expect(updater.progress == nil)
    }

    @Test func onlyRepositoryAssetsAreTrusted() throws {
        #expect(!AppRelease.trustedURL(URL(string: "http://github.com/HR0101/ArkServer/releases/tag/v2")!))
        #expect(!AppRelease.trustedURL(URL(string: "https://evil.example/HR0101/ArkServer/releases/tag/v2")!))
        #expect(!AppRelease.trustedURL(URL(string: "https://github.com/HR0101/Other/releases/tag/v2")!))
        #expect(AppRelease.trustedURL(URL(string: "https://github.com/HR0101/ArkServer/releases/download/v2/ArkServer.dmg")!, download: true))
    }

    private func fixture() throws -> (AppUpdater, UserDefaults, URLSession, String) {
        let suite = "UpdaterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateMockProtocol.self]
        let session = URLSession(configuration: configuration)
        return (AppUpdater(defaults: defaults, session: session, version: "1.0", build: "1", presentsWindows: false), defaults, session, suite)
    }

    private func finish(_ updater: AppUpdater) async {
        for _ in 0..<500 {
            if !updater.isBusy { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Update check timed out")
    }

    private func releaseJSON(tag: String = "v2.0.0") -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/HR0101/ArkServer/releases/tag/\(tag)",
         "body":"Release notes","draft":false,"prerelease":false,
         "assets":[{"name":"ArkServer.dmg","browser_download_url":"https://github.com/HR0101/ArkServer/releases/download/\(tag)/ArkServer.dmg"}]}
        """.utf8)
    }
}

private final class UpdateMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, Data, Error?) = (200, Data(), nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data, error) = Self.response
        if let error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
