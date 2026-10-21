import Foundation
import Testing

@testable import VMRunner

struct DownloadPolicyTests {
    @Test(arguments: [
        "https://updates.cdn-apple.com/2026FallFCS/a/UniversalMac_27.0.1_26A434_Restore.ipsw",
        "https://mirror.stream.centos.org/10-stream/BaseOS/aarch64/iso/CentOS-Stream-10-20261019.0-aarch64-boot.iso",
        "https://api.ipsw.me/v4/device/Mac14,15?type=ipsw",
    ])
    func allowsTheHostsTheAppUses(url: String) throws {
        _ = try DownloadPolicy.validate(try #require(URL(string: url)))
    }

    @Test(arguments: [
        "http://updates.cdn-apple.com/a.ipsw",  // not HTTPS
        "https://evil.example.com/a.ipsw",  // other host
        "https://apple.com.evil.example.com/a.ipsw",  // suffix spoof
        "https://notapple.com/a.ipsw",  // suffix without a dot boundary
        "https://user:pass@updates.cdn-apple.com/a.ipsw",  // credentials in the URL
        "https://updates.cdn-apple.com:8443/a.ipsw",  // unexpected port
        "file:///etc/passwd",
        "ftp://updates.cdn-apple.com/a.ipsw",
    ])
    func rejectsEverythingElse(url: String) throws {
        let parsed = try #require(URL(string: url))
        #expect(throws: SetupError.self) { try DownloadPolicy.validate(parsed) }
    }

    @Test(arguments: ["a.ipsw", "CentOS-Stream-10-20261019.0-aarch64-boot.iso", "UniversalMac_27.0.1_26A434_Restore.ipsw"])
    func acceptsPlainFileNames(name: String) throws {
        let url = try #require(URL(string: "https://updates.cdn-apple.com/x/\(name)"))
        #expect(try DownloadPolicy.cacheFileName(for: url) == name)
    }

    @Test(arguments: ["https://updates.cdn-apple.com/x/..", "https://updates.cdn-apple.com/x/.hidden", "https://updates.cdn-apple.com/"])
    func rejectsFileNamesThatCouldEscapeTheCache(url: String) throws {
        let parsed = try #require(URL(string: url))
        #expect(throws: SetupError.self) { try DownloadPolicy.cacheFileName(for: parsed) }
    }

    @Test(arguments: ["Mac14,15", "Mac15,12", "VirtualMac2,1"])
    func acceptsMacModelIdentifiers(identifier: String) throws {
        #expect(try DownloadPolicy.validateMachineModel(identifier) == identifier)
    }

    @Test(arguments: ["", "../../etc", "Mac14,15/../x", "Mac14,15?x=1", "Mac 14,15", "Mac14"])
    func rejectsAnythingThatCouldChangeTheCatalogURL(identifier: String) {
        #expect(throws: SetupError.self) { try DownloadPolicy.validateMachineModel(identifier) }
    }

    @Test func redirectsOutsideThePolicyAreBlocked() throws {
        let allowed = URLRequest(url: try #require(URL(string: "https://updates.cdn-apple.com/b.ipsw")))
        let blocked = URLRequest(url: try #require(URL(string: "http://updates.cdn-apple.com/b.ipsw")))
        #expect(RedirectPolicy.allowed(allowed) != nil)
        #expect(RedirectPolicy.allowed(blocked) == nil)
    }
}

struct DownloadMechanicsTests {
    @Test func aCancelledTaskNeverStartsTheTransfer() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = FileDownloader(resumeKey: "x", workDirectory: directory) { _, _ in }
        let url = try #require(URL(string: "https://updates.cdn-apple.com/never-requested.ipsw"))

        let task = Task { try await downloader.download(from: url) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers.isEmpty, "nothing should be written for a download that never started: \(leftovers)")
    }

    @Test func downloadsFromOutsideThePolicyAreRefusedBeforeAnyRequest() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = FileDownloader(resumeKey: "x", workDirectory: directory) { _, _ in }

        await #expect(throws: SetupError.self) {
            try await downloader.download(from: try #require(URL(string: "http://evil.example.com/a.ipsw")))
        }
    }

    @Test func hashingStopsWhenTheCallerIsCancelled() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "big.bin")
        try Data(repeating: 7, count: 96 << 20).write(to: file)

        let task = Task { try await Checksums.hexDigest(of: file, algorithm: .sha256) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func throttlePassesTheFirstEventAndSuppressesAnImmediateSecond() {
        let throttle = Throttle(interval: 60)
        #expect(throttle.allow())
        #expect(!throttle.allow())
    }

    @Test func hexStringPadsEveryByteToTwoDigits() {
        #expect([0x00, 0x0F, 0xFF, 0xA0].hexString == "000fffa0")
    }
}

struct ChecksumTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test func sha256OfKnownInput() async throws {
        let file = temporaryFile()
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let digest = try await Checksums.hexDigest(of: file, algorithm: .sha256)
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func mismatchedChecksumThrows() async throws {
        let file = temporaryFile()
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: SetupError.self) {
            try await Checksums.verify(file, against: Checksum(algorithm: .sha256, value: "00"))
        }
    }
}

struct CatalogTests {
    @Test func parsesCentOSChecksumFile() {
        let text = """
            # CentOS-Stream-10-20261019.0-aarch64-boot.iso: 1026574336 bytes
            SHA256 (CentOS-Stream-10-20261019.0-aarch64-boot.iso) = 5ac47d11e9b4deb578f6c9fb0ba9b43f3ee19b3c3f8ce9c0b7b459ee4531c530
            """
        #expect(LinuxCatalog.parseSHA256(text) == "5ac47d11e9b4deb578f6c9fb0ba9b43f3ee19b3c3f8ce9c0b7b459ee4531c530")
    }

    @Test func ipswDecodingKeepsOnlySignedGuestCapableBuilds() throws {
        let json = """
            {"firmwares":[
             {"version":"27.0.1","buildid":"26A434","url":"https://x/a.ipsw","filesize":10,"sha256sum":"aa","signed":true},
             {"version":"26.0","buildid":"25A354","url":"https://x/b.ipsw","filesize":10,"sha256sum":"bb","signed":false},
             {"version":"11.7","buildid":"20G1","url":"https://x/c.ipsw","filesize":10,"sha256sum":"cc","signed":true}
            ]}
            """
        let firmwares = try IPSWCatalog.decode(Data(json.utf8))
        #expect(firmwares.map(\.buildid) == ["26A434"])
        #expect(firmwares[0].checksum == Checksum(algorithm: .sha256, value: "aa"))
    }
}
