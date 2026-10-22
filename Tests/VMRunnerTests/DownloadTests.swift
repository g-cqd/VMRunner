import CryptoKit
import Foundation
import Testing

@testable import VMRunner

struct DownloadPolicyTests {
    @Test(arguments: [
        "https://updates.cdn-apple.com/2026FallFCS/a/UniversalMac_27.0.1_26A434_Restore.ipsw",
        "https://mirror.stream.centos.org/10-stream/BaseOS/aarch64/iso/CentOS-Stream-10-20261019.0-aarch64-boot.iso",
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
        "https://api.ipsw.me/v4/device/Mac14,15?type=ipsw",  // the catalog serves metadata, not files
        "https://ipsw.me/a.ipsw",
        "https://salsa.debian.org/user/project/-/raw/main/a.iso",  // hosts user content
        "https://people.debian.org/~someone/a.iso",
        "https://debian.org/a.iso",  // the bare domain is not a pinned host
        "https://evil.apple.com.example/a.ipsw",  // looks like Apple, is not
        "https://www.apple.com/a.ipsw",  // subdomains of a vendor are not pinned
        "https://apple.com/a.ipsw",
        "https://cdn-apple.com/a.ipsw",
        "https://centos.org/a.iso",
        "https://updates.cdn-apple.com./a.ipsw",  // trailing dot
    ])
    func rejectsEverythingElse(url: String) throws {
        let parsed = try #require(URL(string: url))
        #expect(throws: SetupError.self) { try DownloadPolicy.validate(parsed) }
    }

    @Test func theCatalogHostIsAcceptedForMetadataOnly() throws {
        let catalog = try #require(URL(string: "https://api.ipsw.me/v4/device/Mac14,15?type=ipsw"))
        _ = try DownloadPolicy.validateMetadata(catalog)
        _ = try DownloadPolicy.validateMetadata(try #require(URL(string: "https://deb.debian.org/debian/dists/stable/Release")))
        for refused in ["https://salsa.debian.org/a", "https://evil.apple.com.example/a", "https://ipsw.me/a", "http://api.ipsw.me/a"] {
            let url = try #require(URL(string: refused))
            #expect(throws: SetupError.self, "\(refused)") { try DownloadPolicy.validateMetadata(url) }
        }
        #expect(throws: SetupError.self) { try DownloadPolicy.validate(catalog) }
    }

    @Test func aSmallDocumentFromAnUnpinnedHostIsRefusedBeforeAnyRequest() async throws {
        let url = try #require(URL(string: "https://salsa.debian.org/user/project/-/raw/main/SHA256SUMS"))
        await #expect(throws: SetupError.self) { try await Fetch.fetchSmall(url) }
    }

    @Test func onlyTheRestoreImageHostServesRestoreImages() throws {
        let good = try #require(URL(string: "https://updates.cdn-apple.com/2026FallFCS/x/UniversalMac_27.0.1_26A434_Restore.ipsw"))
        _ = try DownloadPolicy.validateRestoreImage(good)
        for refused in [
            "https://updates.cdn-apple.com/x/notes.txt", "https://mirror.stream.centos.org/a.ipsw",
            "https://api.ipsw.me/a.ipsw", "https://updates.cdn-apple.com/x/",
        ] {
            let url = try #require(URL(string: refused))
            #expect(throws: SetupError.self, "\(refused)") { try DownloadPolicy.validateRestoreImage(url) }
        }
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

    @Test func aDownloadCannotBeRedirectedToTheCatalogHost() throws {
        let catalog = URLRequest(url: try #require(URL(string: "https://api.ipsw.me/v4/ipsw/x")))
        #expect(RedirectPolicy.allowed(catalog) == nil)
        #expect(RedirectPolicy.allowed(catalog, metadata: true) != nil)
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

    @Test func hexStringWritesTwoLowercaseDigitsForEveryByte() {
        let bytes = (0...255).map { UInt8($0) }
        #expect(bytes.hexString == bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined())
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

    @Test func aFileLongerThanOneReadIsHashedWhole() async throws {
        let file = temporaryFile()
        let bytes = Data((0..<(9 << 20) + 5).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try await Checksums.hexDigest(of: file, algorithm: .sha256) == SHA256.hash(data: bytes).hexString)
    }

    @Test func anEmptyFileHashesToTheDigestOfNothing() async throws {
        let file = temporaryFile()
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(
            try await Checksums.hexDigest(of: file, algorithm: .sha256)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func sha1IsRefusedBeforeTheFileIsOpened() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "absent-\(UUID().uuidString).bin")
        let error = await #expect(throws: SetupError.self) { try await Checksums.hexDigest(of: missing, algorithm: .refused("sha1")) }
        guard case .weakChecksum(let name) = error else {
            Issue.record("expected weakChecksum, got \(String(describing: error))")
            return
        }
        #expect(name == missing.lastPathComponent)
    }
}

struct CatalogTests {
    private static let digest = String(repeating: "ab", count: 32)

    private static func entry(_ build: String, version: String = "27.0.1", url: String, sha256: String? = digest, signed: Bool = true)
        -> String
    {
        let hash = sha256.map { "\"\($0)\"" } ?? "null"
        return #"{"version":"\#(version)","buildid":"\#(build)","url":"\#(url)","filesize":10,"sha256sum":\#(hash),"signed":\#(signed)}"#
    }

    private static func decode(_ entries: String...) throws -> [IPSWFirmware] {
        try IPSWCatalog.decode(Data(#"{"firmwares":[\#(entries.joined(separator: ","))]}"#.utf8))
    }

    private static let apple = "https://updates.cdn-apple.com/2026FallFCS/a/UniversalMac_27.0.1_26A434_Restore.ipsw"

    @Test func ipswDecodingKeepsOnlySignedGuestCapableBuilds() throws {
        let firmwares = try Self.decode(
            Self.entry("26A434", url: Self.apple),
            Self.entry("25A354", version: "26.0", url: Self.apple, signed: false),
            Self.entry("20G1", version: "11.7", url: Self.apple))
        #expect(firmwares.map(\.buildid) == ["26A434"])
        #expect(firmwares[0].checksum == Checksum(algorithm: .sha256, value: Self.digest))
    }

    @Test(arguments: [
        "https://api.ipsw.me/v4/ipsw/download/Mac14,15/26A434",  // the catalog is not a file host
        "https://salsa.debian.org/user/project/-/raw/main/UniversalMac_27.0.1_26A434_Restore.ipsw",
        "https://evil.apple.com.example/UniversalMac_27.0.1_26A434_Restore.ipsw",
        "https://www.apple.com/UniversalMac_27.0.1_26A434_Restore.ipsw",
        "https://mirror.stream.centos.org/UniversalMac_27.0.1_26A434_Restore.ipsw",
        "http://updates.cdn-apple.com/UniversalMac_27.0.1_26A434_Restore.ipsw",
        "https://updates.cdn-apple.com/x/notes.txt",
    ])
    func ipswDecodingDropsEntriesOnOtherHosts(url: String) throws {
        let firmwares = try Self.decode(Self.entry("26A434", url: url), Self.entry("26A428", url: Self.apple))
        #expect(firmwares.map(\.buildid) == ["26A428"])
    }

    @Test(arguments: [
        nil, "", "aa", String(repeating: "AB", count: 32), String(repeating: "ab", count: 33), String(repeating: "g", count: 64),
        String(repeating: "\u{FF11}", count: 64),  // full-width digits
    ])
    func ipswDecodingRequiresAnExact64DigitLowercaseSHA256(sha256: String?) throws {
        let firmwares = try Self.decode(Self.entry("26A434", url: Self.apple, sha256: sha256), Self.entry("26A428", url: Self.apple))
        #expect(firmwares.map(\.buildid) == ["26A428"])
    }
}

@MainActor
struct ImageCacheTests {
    private func cachedFile(_ text: String, in directory: URL) throws -> URL {
        let file = directory.appending(path: "image.iso")
        try Data(text.utf8).write(to: file)
        return file
    }

    @Test func aCachedFileWithAMatchingChecksumIsReused() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try cachedFile("abc", in: directory)
        let checksum = Checksum(algorithm: .sha256, value: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let reused = try await ImageStore.validCachedFile(at: file, checksum: checksum, job: SetupJob())

        #expect(reused == file)
    }

    @Test func aStaleCachedFileIsDeletedSoItDownloadsAgain() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try cachedFile("an older build of the same file name", in: directory)
        let checksum = Checksum(algorithm: .sha256, value: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let reused = try await ImageStore.validCachedFile(at: file, checksum: checksum, job: SetupJob())

        #expect(reused == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path), "the stale file must not be left to be reused")
    }

    @Test func withoutAChecksumTheCachedFileIsTrusted() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try cachedFile("whatever", in: directory)

        #expect(try await ImageStore.validCachedFile(at: file, checksum: nil, job: SetupJob()) == file)
    }

    @Test func aMissingFileIsNotCached() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appending(path: "nothing.iso")
        let result = try await ImageStore.validCachedFile(at: missing, checksum: nil, job: SetupJob())
        #expect(result == nil)
    }
}
