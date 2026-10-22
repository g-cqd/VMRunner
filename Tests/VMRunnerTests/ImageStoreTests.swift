import CryptoKit
import Foundation
import Testing

@testable import VMRunner

private func sha256(_ text: String) -> Checksum {
    Checksum(algorithm: .sha256, value: SHA256.hash(data: Data(text.utf8)).hexString)
}

private func contents(of url: URL) throws -> String {
    try #require(String(bytes: try Data(contentsOf: url), encoding: .utf8))
}

/// A URL on an allowed host that no other test serves.
private func uniqueImageURL(_ name: String = "image.iso") throws -> URL {
    try #require(URL(string: "https://updates.cdn-apple.com/stub-\(UUID().uuidString)/\(name)"))
}

@MainActor
struct SharedCacheTests {
    @Test func oneFileNameWithDifferentChecksumsKeepsEveryFile() async throws {
        let images = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: images) }
        let url = try uniqueImageURL()
        let job = SetupJob()

        StubURLProtocol.serve(Data("first build".utf8), at: url)
        let first = try await ImageStore.fetch(
            url, checksum: sha256("first build"), job: job, imagesDirectory: images, configuration: StubURLProtocol.configuration())
        // The same name now carries different content, as Debian's mini.iso does, and another machine asks for it.
        StubURLProtocol.serve(Data("second build".utf8), at: url)
        let second = try await ImageStore.fetch(
            url, checksum: sha256("second build"), job: job, imagesDirectory: images, configuration: StubURLProtocol.configuration())

        #expect(first != second)
        #expect(first.lastPathComponent == second.lastPathComponent)
        #expect(try contents(of: first) == "first build", "the first machine's file must survive the second fetch")
        #expect(try contents(of: second) == "second build")
    }

    @Test func aFailedVerificationNeverDeletesAnotherChecksumsFile() async throws {
        let images = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: images) }
        let url = try uniqueImageURL()
        let job = SetupJob()
        StubURLProtocol.serve(Data("first build".utf8), at: url)
        let first = try await ImageStore.fetch(
            url, checksum: sha256("first build"), job: job, imagesDirectory: images, configuration: StubURLProtocol.configuration())

        StubURLProtocol.serve(Data("tampered".utf8), at: url)
        await #expect(throws: SetupError.self) {
            try await ImageStore.fetch(
                url, checksum: sha256("third build"), job: job, imagesDirectory: images, configuration: StubURLProtocol.configuration())
        }

        #expect(try contents(of: first) == "first build")
    }

    @Test func aVerifiedCachedFileIsReusedWithoutANewRequest() async throws {
        let images = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: images) }
        let url = try uniqueImageURL()
        StubURLProtocol.serve(Data("payload".utf8), at: url)
        let job = SetupJob()
        let configuration = StubURLProtocol.configuration()

        let first = try await ImageStore.fetch(
            url, checksum: sha256("payload"), job: job, imagesDirectory: images, configuration: configuration)
        let again = try await ImageStore.fetch(
            url, checksum: sha256("payload"), job: job, imagesDirectory: images, configuration: configuration)

        #expect(first == again)
        #expect(StubURLProtocol.requestCount(for: url) == 1)
    }

    @Test func aDamagedCachedFileIsReplacedByAFreshDownload() async throws {
        let images = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: images) }
        let url = try uniqueImageURL()
        StubURLProtocol.serve(Data("payload".utf8), at: url)
        let job = SetupJob()
        let first = try await ImageStore.fetch(
            url, checksum: sha256("payload"), job: job, imagesDirectory: images, configuration: StubURLProtocol.configuration())
        try Data("damaged".utf8).write(to: first)

        let again = try await ImageStore.fetch(
            url, checksum: sha256("payload"), job: job, imagesDirectory: images, configuration: StubURLProtocol.configuration())

        #expect(try contents(of: again) == "payload")
    }

    @Test func aChecksumNeverBecomesAPathAsItIs() throws {
        let images = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: images) }
        let url = try uniqueImageURL()
        let hash = SHA256.hash(data: Data("x".utf8)).hexString

        for hostile in ["../../outside", "/etc", "", "a/b", String(repeating: "A", count: 64) + "/.."] {
            let directory = ImageStore.cacheDirectory(
                for: url, checksum: Checksum(algorithm: .sha256, value: hostile), in: images)
            #expect(directory.deletingLastPathComponent().standardizedFileURL == images.standardizedFileURL, "\(hostile)")
        }
        let lower = ImageStore.cacheDirectory(for: url, checksum: Checksum(algorithm: .sha256, value: hash), in: images)
        let upper = ImageStore.cacheDirectory(for: url, checksum: Checksum(algorithm: .sha256, value: hash.uppercased()), in: images)
        #expect(lower == upper)
        #expect(lower.lastPathComponent == hash)
    }

    @Test func aFileThatAppearedDuringTheDownloadIsReplacedByTheVerifiedOne() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "image.iso")
        let verified = directory.appending(path: "download")
        try Data("verified".utf8).write(to: verified)
        try Data("planted by a racing setup".utf8).write(to: destination)

        try ImageStore.install(verified, at: destination)

        #expect(try contents(of: destination) == "verified")
        #expect(!FileManager.default.fileExists(atPath: verified.path))
    }
}

@MainActor
struct SymbolicLinkTests {
    /// A cache slot whose file name is a link to a file elsewhere.
    private func linkedFile(in directory: URL) throws -> (link: URL, target: URL) {
        let target = directory.appending(path: "elsewhere.bin")
        try Data("not the installer".utf8).write(to: target)
        let link = directory.appending(path: "image.iso")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return (link, target)
    }

    @Test func aLinkAtTheDestinationIsRefusedAndItsTargetKept() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (link, target) = try linkedFile(in: directory)

        #expect(await refusesCachedFile(at: link, checksum: sha256("not the installer")))
        #expect(await refusesCachedFile(at: link, checksum: nil))
        #expect(try contents(of: target) == "not the installer", "a refused link must not be followed and deleted")
    }

    /// Whether the cache refuses the file with a setup error. Written as a plain function: two `#expect(throws:)`
    /// closures over an async call in one test crash the release optimizer ("While splitting coroutine").
    private func refusesCachedFile(at url: URL, checksum: Checksum?) async -> Bool {
        do {
            _ = try await ImageStore.validCachedFile(at: url, checksum: checksum, job: SetupJob())
            return false
        } catch is SetupError {
            return true
        } catch {
            return false
        }
    }

    @Test func fetchRefusesALinkAtTheDestination() async throws {
        let images = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: images) }
        let url = try uniqueImageURL()
        let checksum = sha256("payload")
        StubURLProtocol.serve(Data("payload".utf8), at: url)
        let slot = ImageStore.cacheDirectory(for: url, checksum: checksum, in: images)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        let (_, target) = try linkedFile(in: slot)

        await #expect(throws: SetupError.self) {
            try await ImageStore.fetch(
                url, checksum: checksum, job: SetupJob(), imagesDirectory: images, configuration: StubURLProtocol.configuration())
        }
        #expect(try contents(of: target) == "not the installer")
    }

    @Test func hashingNeverFollowsALink() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (link, _) = try linkedFile(in: directory)

        await #expect(throws: SetupError.self) { try await Checksums.hexDigest(of: link, algorithm: .sha256) }
        await #expect(throws: SetupError.self) { try await Checksums.verify(link, against: sha256("not the installer")) }
        // A directory is not a regular file either.
        await #expect(throws: SetupError.self) { try await Checksums.hexDigest(of: directory, algorithm: .sha256) }
    }
}

struct MachineInstallerTests {
    private func makeBundle(in directory: URL, id: UUID = UUID()) throws -> VMBundle {
        let bundle = VMBundle(id: id, in: directory)
        try bundle.create()
        return bundle
    }

    @Test func overwritingTheCacheAfterwardsDoesNotChangeTheMachinesInstaller() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = directory.appending(path: "cached.iso")
        try Data("the verified installer".utf8).write(to: cached)
        let bundle = try makeBundle(in: directory)

        let kept = try ImageStore.keepInstaller(cached, in: bundle)
        // The file is rewritten in place, as a second download or a malicious process could.
        let handle = try FileHandle(forWritingTo: cached)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("something else entirely".utf8))
        try handle.close()

        #expect(kept == bundle.installer)
        #expect(try contents(of: kept) == "the verified installer")
    }

    @Test func removingTheCacheLeavesTheMachinesInstaller() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = directory.appending(path: "cached.iso")
        try Data("installer".utf8).write(to: cached)
        let bundle = try makeBundle(in: directory)
        _ = try ImageStore.keepInstaller(cached, in: bundle)

        try FileManager.default.removeItem(at: cached)

        #expect(try contents(of: bundle.installer) == "installer")
    }

    @Test func anInstallReadsACloneOfItsOwnThatChangesToTheCachedFileDoNotReach() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = directory.appending(path: "UniversalMac_26.1_25B78_Restore.ipsw")
        try Data("the verified restore image".utf8).write(to: cached)

        let copy = try ImageStore.installCopy(of: cached)
        #expect(copy.deletingLastPathComponent().path == cached.deletingLastPathComponent().path)
        #expect(copy.lastPathComponent.hasSuffix("-UniversalMac_26.1_25B78_Restore.ipsw") && copy.lastPathComponent.hasPrefix(".install-"))
        try Data("replaced".utf8).write(to: cached)
        #expect(try contents(of: copy) == "the verified restore image")
        #expect(try ImageStore.installCopy(of: cached) != copy, "each install gets a clone of its own")
    }

    @Test func aLinkOrANameWithNothingBehindItIsNeverClonedForAnInstall() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "elsewhere.ipsw")
        try Data("x".utf8).write(to: target)
        let link = directory.appending(path: "UniversalMac.ipsw")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: SetupError.self) { try ImageStore.installCopy(of: link) }
        #expect(throws: SetupError.self) { try ImageStore.installCopy(of: directory.appending(path: "missing.ipsw")) }
    }

    @Test func theLaunchSweepDeletesOnlyLeftOverInstallClones() throws {
        let fileManager = FileManager.default
        let images = try scratchDirectory()
        defer { try? fileManager.removeItem(at: images) }
        let outside = try scratchDirectory()
        defer { try? fileManager.removeItem(at: outside) }
        let folder = images.appending(path: String(repeating: "a", count: 64), directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let cached = folder.appending(path: "Restore.ipsw")
        try Data("image".utf8).write(to: cached)
        let nestedClone = try ImageStore.installCopy(of: cached)
        let flatClone = images.appending(path: ".install-1-Restore.ipsw")
        try Data("left over".utf8).write(to: flatClone)
        // Kept: a link with the prefix, the file it points to, a folder with the prefix, a clone two levels down, and the
        // files behind a link to a folder.
        let target = outside.appending(path: ".install-2-elsewhere.ipsw")
        try Data("not ours".utf8).write(to: target)
        let link = images.appending(path: ".install-3-link.ipsw")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        let prefixedFolder = images.appending(path: ".install-4-folder", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: prefixedFolder, withIntermediateDirectories: true)
        let deeper = folder.appending(path: "sub", directoryHint: .isDirectory).appending(path: ".install-5-deep.ipsw")
        try fileManager.createDirectory(at: deeper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("deeper".utf8).write(to: deeper)
        try fileManager.createSymbolicLink(at: images.appending(path: "linked"), withDestinationURL: outside)

        ImageStore.sweepInstallClones(in: images)

        #expect(!fileManager.fileExists(atPath: nestedClone.path) && !fileManager.fileExists(atPath: flatClone.path))
        #expect(try contents(of: cached) == "image", "the cached file itself stays")
        #expect(try contents(of: target) == "not ours", "a link is not followed, as a file or as a folder")
        #expect((try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil, "and the link itself stays")
        #expect(fileManager.fileExists(atPath: prefixedFolder.path) && fileManager.fileExists(atPath: deeper.path))
    }

    @Test func keepingAgainReplacesTheCopyOfAResumedSetup() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(in: directory)
        let older = directory.appending(path: "older.iso")
        let newer = directory.appending(path: "newer.iso")
        try Data("older".utf8).write(to: older)
        try Data("newer".utf8).write(to: newer)

        _ = try ImageStore.keepInstaller(older, in: bundle)
        _ = try ImageStore.keepInstaller(newer, in: bundle)

        #expect(try contents(of: bundle.installer) == "newer")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path)
        #expect(leftovers == [VMBundle.installerName], "no staging file may stay behind: \(leftovers)")
    }

    @Test func aLinkIsNotKept() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "target.iso")
        try Data("t".utf8).write(to: target)
        let link = directory.appending(path: "link.iso")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: SetupError.self) { try ImageStore.keepInstaller(link, in: try makeBundle(in: directory)) }
    }

    @Test func aDuplicateUsesItsOwnCopyNotTheSourcesPath() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeBundle(in: directory)
        let copy = try makeBundle(in: directory)
        try Data("copy".utf8).write(to: copy.installer)

        // The duplicate's configuration still stores the source's path.
        #expect(copy.installerFile(for: source.installer.path) == copy.installer)
        #expect(copy.installerFile(for: copy.installer.path) == copy.installer)
    }

    @Test func aPathTheUserChoseIsUsedAsItIs() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(in: directory)
        try Data("own".utf8).write(to: bundle.installer)

        let chosen = directory.appending(path: "Installer.iso")  // the right name, but not inside a machine's bundle
        #expect(bundle.installerFile(for: chosen.path) == chosen)
        #expect(bundle.installerFile(for: "/Users/someone/debian.iso").path == "/Users/someone/debian.iso")
    }

    @Test func aBundleWithoutACopyKeepsTheStoredPath() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(in: directory)
        let legacy = AppPaths.images.appending(path: "ubuntu.iso").path  // a machine made before installers were cloned

        #expect(bundle.installerFile(for: legacy).path == legacy)
    }
}
