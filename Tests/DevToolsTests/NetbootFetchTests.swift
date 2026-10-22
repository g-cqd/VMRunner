import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import DevTools

/// `vmr guest fetch alpine-netboot` against a fixture release: a small archive built with the system `tar`, served by a fake
/// downloader, with the real `tar` and `gzip` doing the unpacking and a scripted `gpg`.
struct NetbootFetchTests {
    private static let version = "3.24.2"
    private static let directoryURL = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/"
    private static let keyURL = AlpineNetboot.keyURL

    // MARK: Fixture

    /// The files the vendor's server would serve, keyed by URL.
    struct Mirror: ArchiveDownloader {
        var files: [String: Data]

        func download(from source: URL, to destination: URL) async throws {
            guard let data = files[source.absoluteString] else { throw ToolError("HTTP 404: \(source.absoluteString)") }
            try data.write(to: destination)
        }
    }

    /// Notes collected from the fetch's progress lines.
    final class Said: Sendable {
        private let lines = Mutex<[String]>([])
        func add(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
        var text: String { all.joined(separator: "\n") }
    }

    /// A kernel as Alpine ships it: an EFI application with a gzip payload that holds the arm64 `Image`.
    private static func packagedKernel(payload image: [UInt8], gzipped: Data) -> Data {
        var header = Data([0x4D, 0x5A, 0, 0]) + Data("zimg".utf8)
        let offset: UInt32 = 64
        let size = UInt32(gzipped.count)
        for value in [offset, size] { header += Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }) }
        header += Data(repeating: 0, count: 8) + Data("gzip".utf8) + Data(repeating: 0, count: 4)
        return header + Data(repeating: 0, count: 64 - header.count) + gzipped
    }

    private static var imageBytes: [UInt8] {
        var image = [UInt8](repeating: 0x20, count: 256)
        image.replaceSubrange(56..<60, with: [0x41, 0x52, 0x4D, 0x64])
        return image
    }

    /// Builds `alpine-netboot-<version>-aarch64.tar.gz` in `directory`; `extra` can add entries (a link, say) before it is packed.
    private static func archive(in directory: URL, extra: (URL) throws -> Void = { _ in }, members: [String] = ["boot"]) async throws
        -> Data
    {
        let staging = directory.appending(path: "staging", directoryHint: .isDirectory)
        let boot = staging.appending(path: "boot", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: boot, withIntermediateDirectories: true)
        let image = boot.appending(path: "Image")
        try Data(imageBytes).write(to: image)
        let zip = try await ProcessRunner.run(CommandSpec(executable: "/usr/bin/gzip", arguments: ["-k", "-f", image.path]))
        #expect(zip.succeeded)
        let gzipped = try Data(contentsOf: boot.appending(path: "Image.gz"))
        try FileManager.default.removeItem(at: image)
        try FileManager.default.removeItem(at: boot.appending(path: "Image.gz"))
        try packagedKernel(payload: imageBytes, gzipped: gzipped).write(to: boot.appending(path: "vmlinuz-virt"))
        try Data("initramfs".utf8).write(to: boot.appending(path: "initramfs-virt"))
        try Data("modloop".utf8).write(to: boot.appending(path: "modloop-virt"))
        try Data("not wanted".utf8).write(to: boot.appending(path: "vmlinuz-rpi"))
        try extra(staging)

        let output = directory.appending(path: "archive.tar.gz")
        let pack = try await ProcessRunner.run(
            CommandSpec(executable: "/usr/bin/tar", arguments: ["-czf", output.path, "-C", staging.path] + members))
        #expect(pack.succeeded, "\(pack.standardError)")
        return try Data(contentsOf: output)
    }

    private static func listing(signed: Bool = true) -> Data {
        let name = AlpineNetboot.archiveName(version)
        var html = "<a href=\"\(name)\">x</a><a href=\"\(name).sha256\">x</a>"
        if signed { html += "<a href=\"\(name).asc\">x</a>" }
        return Data(html.utf8)
    }

    private static func mirror(archive: Data, checksum: String? = nil, signed: Bool = true) -> Mirror {
        let name = AlpineNetboot.archiveName(version)
        let digest = checksum ?? SHA256.hash(data: archive).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        return Mirror(files: [
            directoryURL: listing(signed: signed), directoryURL + name: archive,
            directoryURL + name + ".sha256": Data("\(digest)  \(name)\n".utf8), directoryURL + name + ".asc": Data("signature".utf8),
            keyURL: Data("key".utf8),
        ])
    }

    private static let colonListing = """
        pub:-:4096:1:293ACD0907D9495A:1418203196:::-:::scESC::::::23::0:
        fpr:::::::::\(AlpineNetboot.keyFingerprint):
        sub:-:4096:1:9E2CE29C63FE7A06:1418203196::::::e::::::23:
        fpr:::::::::498A2E7C598FFE67966416B19E2CE29C63FE7A06:
        """

    private static let goodStatus = """
        [GNUPG:] GOODSIG 293ACD0907D9495A Natanael Copa <ncopa@alpinelinux.org>
        [GNUPG:] VALIDSIG \(AlpineNetboot.keyFingerprint) 2026-09-17 1789675985 0 4 0 1 10 00 \(AlpineNetboot.keyFingerprint)
        """

    /// A `gpg` that answers the three calls the fetch makes.
    private static func scriptedGPG(keyListing: String = colonListing, status: String = goodStatus, verifyStatus: Int32 = 0)
        -> @Sendable (CommandSpec) async throws -> CommandResult
    {
        { spec in
            guard spec.executable == "/fake/gpg" else { return try await ProcessRunner.run(spec) }
            let arguments = spec.arguments
            if arguments.contains("--show-keys") {
                return CommandResult(status: 0, standardOutput: keyListing, standardError: "", timedOut: false)
            }
            if arguments.contains("--verify") {
                return CommandResult(status: verifyStatus, standardOutput: status, standardError: "gpg: Good signature", timedOut: false)
            }
            return CommandResult(status: 0, standardOutput: "", standardError: "", timedOut: false)
        }
    }

    private func fetch(
        in directory: URL, mirror: Mirror, gpg: String? = "/fake/gpg",
        run: @escaping @Sendable (CommandSpec) async throws -> CommandResult = Self.scriptedGPG(), said: Said = Said()
    ) async throws -> NetbootFiles {
        let scratch = try GuestScratch(path: directory.appending(path: "scratch").path, workingDirectory: directory)
        var job = NetbootFetch(scratch: scratch)
        job.dependencies = NetbootDependencies(run: run, downloader: { _ in mirror }, gpg: gpg)
        job.say = { said.add($0) }
        return try await job.run()
    }

    // MARK: Tests

    @Test
    func theNewestSignedReleaseIsDownloadedCheckedAndUnpackedIntoTheThreeFilesAndTheKernelImage() async throws {
        try await withTemporaryDirectory { directory in
            let said = Said()
            let archive = try await Self.archive(in: directory)
            let files = try await fetch(in: directory, mirror: Self.mirror(archive: archive), said: said)

            #expect(files.version == Self.version)
            for file in [files.packagedKernel, files.initramfs, files.directory.appending(path: "modloop-virt"), files.kernel] {
                #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)")
            }
            #expect(try Data(contentsOf: files.kernel) == Data(Self.imageBytes), "the kernel is the decompressed payload")
            #expect(try String(contentsOf: files.initramfs, encoding: .utf8) == "initramfs")
            #expect(try String(contentsOf: files.releaseFile, encoding: .utf8) == "\(Self.version)\n")
            let unpacked = try FileManager.default.contentsOfDirectory(atPath: files.directory.path).sorted()
            #expect(
                unpacked == ["Image-virt", "initramfs-virt", "modloop-virt", "release", "vmlinuz-virt"],
                "nothing else of the archive is written")
            #expect(!FileManager.default.fileExists(atPath: files.directory.appending(path: "vmlinuz-rpi").path))
            #expect(said.text.contains("sha256 OK") && said.text.contains("signature OK"))
            let archiveCopy = files.directory.deletingLastPathComponent().appending(
                path: "download/\(AlpineNetboot.archiveName(Self.version))")
            #expect(!FileManager.default.fileExists(atPath: archiveCopy.path), "the large archive is deleted once unpacked")
            let mode = try FileManager.default.attributesOfItem(atPath: files.initramfs.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
    }

    @Test
    func aNewerReleaseWithoutASignatureIsPassedOverAndSaid() async throws {
        try await withTemporaryDirectory { directory in
            let said = Said()
            let archive = try await Self.archive(in: directory)
            var mirror = Self.mirror(archive: archive)
            let newer = AlpineNetboot.archiveName("3.24.3")
            mirror.files[Self.directoryURL] = Self.listing() + Data("<a href=\"\(newer)\">x</a><a href=\"\(newer).sha256\">x</a>".utf8)
            let files = try await fetch(in: directory, mirror: mirror, said: said)
            #expect(files.version == Self.version)
            #expect(said.text.contains("passed over 3.24.3"))
        }
    }

    @Test
    func aWrongChecksumIsRefusedAndNothingIsUnpacked() async throws {
        try await withTemporaryDirectory { directory in
            let archive = try await Self.archive(in: directory)
            let mirror = Self.mirror(archive: archive, checksum: String(repeating: "0", count: 64))
            await #expect(throws: ToolError.self) { try await fetch(in: directory, mirror: mirror) }
            let netboot = directory.appending(path: "scratch/netboot")
            #expect(try FileManager.default.contentsOfDirectory(atPath: netboot.path).isEmpty)
        }
    }

    @Test
    func aSignatureGpgDoesNotCallGoodIsRefused() async throws {
        try await withTemporaryDirectory { directory in
            let archive = try await Self.archive(in: directory)
            let bad = Self.scriptedGPG(status: "[GNUPG:] BADSIG 293ACD0907D9495A Natanael Copa", verifyStatus: 1)
            let error = await #expect(throws: ToolError.self) {
                try await fetch(in: directory, mirror: Self.mirror(archive: archive), run: bad)
            }
            #expect(error?.message.contains("does not report a good signature") == true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "scratch/netboot").path).isEmpty)
        }
    }

    @Test
    func aSignatureByAnotherKeyIsRefusedEvenWhenGpgIsHappy() async throws {
        try await withTemporaryDirectory { directory in
            let archive = try await Self.archive(in: directory)
            let other = String(repeating: "B", count: 40)
            let status = "[GNUPG:] GOODSIG 1 x\n[GNUPG:] VALIDSIG \(other) 2026-09-17 1 0 4 0 1 10 00 \(other)"
            await #expect(throws: ToolError.self) {
                try await fetch(in: directory, mirror: Self.mirror(archive: archive), run: Self.scriptedGPG(status: status))
            }
        }
    }

    @Test
    func aKeyFileWhoseFingerprintIsNotThePinnedOneIsRefusedBeforeItIsImported() async throws {
        try await withTemporaryDirectory { directory in
            let archive = try await Self.archive(in: directory)
            let imported = Said()
            let swapped =
                "pub:-:4096:1:AAAAAAAAAAAAAAAA:1:::-:::scESC::::::23::0:\nfpr:::::::::" + String(repeating: "A", count: 40) + ":\n"
            let script = Self.scriptedGPG(keyListing: swapped)
            let watching: @Sendable (CommandSpec) async throws -> CommandResult = { spec in
                if spec.arguments.contains("--import") { imported.add("import") }
                return try await script(spec)
            }
            let error = await #expect(throws: ToolError.self) {
                try await fetch(in: directory, mirror: Self.mirror(archive: archive), run: watching)
            }
            #expect(error?.message.contains("expected only \(AlpineNetboot.keyFingerprint)") == true)
            #expect(imported.all.isEmpty, "an unexpected key is never put in the keyring")
        }
    }

    @Test
    func withoutGpgTheFetchSaysTheSignatureWasNotVerifiedAndGoesOn() async throws {
        try await withTemporaryDirectory { directory in
            let said = Said()
            let archive = try await Self.archive(in: directory)
            _ = try await fetch(in: directory, mirror: Self.mirror(archive: archive), gpg: nil, said: said)
            #expect(said.text.contains("NOT VERIFIED"))
            #expect(!said.text.contains("signature OK"))
        }
    }

    @Test
    func aDirectoryThatIsNotEmptyIsNeverFetchedInto() async throws {
        try await withTemporaryDirectory { directory in
            let archive = try await Self.archive(in: directory)
            let scratch = directory.appending(path: "scratch")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try Data("mine".utf8).write(to: scratch.appending(path: "keep.txt"))
            let error = await #expect(throws: ToolError.self) { try await fetch(in: directory, mirror: Self.mirror(archive: archive)) }
            #expect(error?.message.contains("is not empty") == true)
            #expect(try String(contentsOf: scratch.appending(path: "keep.txt"), encoding: .utf8) == "mine")
        }
    }

    @Test
    func anArchiveWithALinkInItIsRefusedBeforeAnythingIsUnpacked() async throws {
        try await withTemporaryDirectory { directory in
            let archive = try await Self.archive(in: directory) { staging in
                try FileManager.default.createSymbolicLink(
                    atPath: staging.appending(path: "boot/evil").path, withDestinationPath: "/etc/passwd")
            }
            let error = await #expect(throws: ToolError.self) { try await fetch(in: directory, mirror: Self.mirror(archive: archive)) }
            #expect(error?.message.contains("symbolic link") == true, "\(error?.message ?? "")")
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "scratch/netboot").path).isEmpty)
        }
    }

    @Test
    func anArchiveWithAnEntryThatLeavesTheTargetIsRefused() async throws {
        try await withTemporaryDirectory { directory in
            // Entries named `../escape`, made with bsdtar's name substitution.
            let staging = directory.appending(path: "plain", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: staging.appending(path: "escape"))
            let output = directory.appending(path: "evil.tar.gz")
            let pack = try await ProcessRunner.run(
                CommandSpec(
                    executable: "/usr/bin/tar", arguments: ["-czf", output.path, "-P", "-s", "|^|../|", "-C", staging.path, "escape"]))
            #expect(pack.succeeded, "\(pack.standardError)")
            let mirror = Self.mirror(archive: try Data(contentsOf: output))
            let error = await #expect(throws: ToolError.self) { try await fetch(in: directory, mirror: mirror) }
            #expect(error?.message.contains("not safe to unpack") == true, "\(error?.message ?? "")")
            #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appending(path: "escape").path))
        }
    }

    @Test
    func anArchiveWithoutTheKernelIsRefused() async throws {
        try await withTemporaryDirectory { directory in
            let archive = try await Self.archive(in: directory) { staging in
                try FileManager.default.removeItem(at: staging.appending(path: "boot/modloop-virt"))
            }
            let error = await #expect(throws: ToolError.self) { try await fetch(in: directory, mirror: Self.mirror(archive: archive)) }
            #expect(error?.message.contains("boot/modloop-virt") == true)
        }
    }

    @Test
    func aServerThatFailsIsReportedNotSwallowed() async throws {
        try await withTemporaryDirectory { directory in
            let error = await #expect(throws: ToolError.self) { try await fetch(in: directory, mirror: Mirror(files: [:])) }
            #expect(error?.message.contains("404") == true)
        }
    }
}
