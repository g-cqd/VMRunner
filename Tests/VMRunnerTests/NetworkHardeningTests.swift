import Foundation
import Testing

@testable import VMRunner

struct SessionConfigurationTests {
    private func expectCookielessAndCacheless(_ configuration: URLSessionConfiguration) {
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    }

    @Test func smallDocumentsAndDownloadsShareOneEphemeralCookielessConfiguration() {
        let small = Fetch.makeConfiguration()
        let download = FileDownloader.makeConfiguration()

        expectCookielessAndCacheless(small)
        expectCookielessAndCacheless(download)
        #expect(!small.waitsForConnectivity, "a small document should fail fast")
        #expect(download.waitsForConnectivity)
    }

    @Test func aSmallDocumentIsFetchedThroughTheGivenConfiguration() async throws {
        let url = try #require(URL(string: "https://api.ipsw.me/stub-\(UUID().uuidString)/catalog"))
        StubURLProtocol.serve(Data("{\"firmwares\":[]}".utf8), at: url)

        let data = try await Fetch.fetchSmall(url, configuration: StubURLProtocol.configuration())

        #expect(String(bytes: data, encoding: .utf8) == "{\"firmwares\":[]}")
        #expect(StubURLProtocol.requestCount(for: url) == 1)
    }

    @Test func aSmallDocumentOverItsLimitIsRefusedWhetherAnnouncedOrNot() async throws {
        let announced = try #require(URL(string: "https://api.ipsw.me/stub-\(UUID().uuidString)/announced"))
        let chunked = try #require(URL(string: "https://api.ipsw.me/stub-\(UUID().uuidString)/chunked"))
        StubURLProtocol.serve(Data(repeating: 1, count: 500), at: announced)
        StubURLProtocol.serve(
            StubURLProtocol.Reply(chunks: Array(repeating: Data(repeating: 1, count: 100), count: 5)), at: chunked)
        let configuration = StubURLProtocol.configuration()

        for url in [announced, chunked] {
            do {
                _ = try await Fetch.fetchSmall(url, limit: 400, configuration: configuration)
                Issue.record("\(url.lastPathComponent) should have been refused")
            } catch SetupError.responseTooLarge {
                // expected
            } catch {
                Issue.record("expected responseTooLarge for \(url.lastPathComponent), got \(error)")
            }
        }
    }
}

struct SHA1RefusalTests {
    // SHA-1 of "abc".
    private let sha1 = Checksum(algorithm: .refused("sha1"), value: "a9993e364706816aba3e25717850c26c9cd0d89d")

    @Test func aCorrectSHA1CannotVouchForAFile() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "abc")
        try Data("abc".utf8).write(to: file)

        await #expect(throws: SetupError.self) { try await Checksums.verify(file, against: sha1) }
    }

    @MainActor
    @Test func aDownloadWithASHA1ChecksumIsRefusedBeforeAnyRequest() async throws {
        let images = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: images) }
        let url = try #require(URL(string: "https://updates.cdn-apple.com/stub-\(UUID().uuidString)/image.iso"))
        StubURLProtocol.serve(Data("abc".utf8), at: url)

        await #expect(throws: SetupError.self) {
            try await ImageStore.fetch(
                url, checksum: sha1, job: SetupJob(), imagesDirectory: images, configuration: StubURLProtocol.configuration())
        }
        #expect(StubURLProtocol.requestCount(for: url) == 0)
    }
}

struct LatestMacChecksumTests {
    private static let digest = String(repeating: "ab", count: 32)

    private func firmware(build: String, file: String, sha256: String? = digest) throws -> IPSWFirmware {
        IPSWFirmware(
            version: "27.0.1", buildid: build, url: try #require(URL(string: "https://updates.cdn-apple.com/2026FallFCS/x/\(file)")),
            filesize: 10, sha256sum: sha256, signed: true)
    }

    @Test func theChecksumOfTheSameBuildAndFileIsUsed() throws {
        let file = try #require(URL(string: "https://updates.cdn-apple.com/2026FallFCS/other-path/UniversalMac_27.0.1_26A434_Restore.ipsw"))
        let firmwares = [
            try firmware(build: "26A428", file: "UniversalMac_27.0_26A428_Restore.ipsw"),
            try firmware(build: "26A434", file: "UniversalMac_27.0.1_26A434_Restore.ipsw"),
        ]

        let checksum = IPSWCatalog.checksum(forBuild: "26A434", file: file, in: firmwares)

        #expect(checksum == Checksum(algorithm: .sha256, value: Self.digest))
    }

    @Test func aDifferentFileNameOrBuildGivesNoChecksum() throws {
        let file = try #require(URL(string: "https://updates.cdn-apple.com/x/UniversalMac_27.0.1_26A434_Restore.ipsw"))
        let firmwares = [try firmware(build: "26A434", file: "UniversalMac_27.0.1_26A434_Other.ipsw")]

        #expect(IPSWCatalog.checksum(forBuild: "26A434", file: file, in: firmwares) == nil)
        #expect(IPSWCatalog.checksum(forBuild: "99Z1", file: file, in: []) == nil)
        #expect(
            IPSWCatalog.checksum(
                forBuild: "26A434", file: file, in: [try firmware(build: "26A434", file: file.lastPathComponent, sha256: nil)]) == nil)
    }
}

struct PrivateDirectoryTests {
    @Test func aNewDirectoryIsCreatedPrivate() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "a/b/c", directoryHint: .isDirectory)

        try AppPaths.createPrivateDirectory(nested)

        let permissions = try FileManager.default.attributesOfItem(atPath: nested.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
    }

    @Test func anExistingOwnPrivateDirectoryIsAccepted() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try AppPaths.createPrivateDirectory(root)
        try AppPaths.createPrivateDirectory(root)
    }

    @Test func aLinkWhereTheDirectoryShouldBeIsRefused() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = root.appending(path: "Images")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

        #expect(throws: AppPaths.UnsafeDirectory.self) { try AppPaths.createPrivateDirectory(link) }
    }

    @Test func aFileWhereTheDirectoryShouldBeIsRefused() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Images")
        try Data("x".utf8).write(to: file)

        #expect(throws: AppPaths.UnsafeDirectory.self) { try AppPaths.createPrivateDirectory(file) }
    }

    @Test func aDirectoryOtherUsersCanWriteToIsRefused() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let open = root.appending(path: "open", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        // The creation mask may have trimmed the mode; set it as the test needs it.
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: open.path)

        #expect(throws: AppPaths.UnsafeDirectory.self) { try AppPaths.createPrivateDirectory(open) }
    }
}
