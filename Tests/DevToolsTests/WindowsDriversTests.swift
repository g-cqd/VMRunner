import CryptoKit
import Foundation
import Testing

@testable import DevTools

/// `vmr windows drivers verify`: the digest of a scratch file against a list the test writes, never the user's files.
struct WindowsDriversTests {
    /// SHA-256 of the three bytes "abc" (FIPS 180-4 example).
    private static let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private static let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func list(entries: String) -> String {
        #"{"schema": 1, "about": "test", "entries": [\#(entries)]}"#
    }

    private static let abcEntry =
        #"{"sha256": "\#(abc.uppercased())", "name": "Test disc", "version": "1.2", "notes": "scratch, 2026-10-25"}"#

    /// A package root with the given list and a file `disc.iso` holding "abc".
    private func withFixture(list: String?, _ body: (URL) async throws -> Void) async throws {
        try await withTemporaryDirectory { directory in
            var files = ["disc.iso": "abc"]
            files[DriverPins.relativePath] = list
            try write(files, to: directory)
            try await body(directory)
        }
    }

    private func verify(_ file: String, in directory: URL) async throws -> Invocation {
        try await VMR.vmr(["windows", "drivers", "verify", file, "--root", directory.path], in: directory)
    }

    @Test
    func hashesAKnownFileInChunks() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "vmr-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(try FileDigest.sha256(ofFileAt: url) == Self.abc)
        // Larger than three chunks, and not a multiple of the chunk size.
        let big = Data((0..<(FileDigest.chunkBytes * 3 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try big.write(to: url)
        let expected = SHA256.hash(data: big).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        #expect(try FileDigest.sha256(ofFileAt: url) == expected)
    }

    @Test
    func aMatchPrintsTheEntryAndExitsZero() async throws {
        try await withFixture(list: Self.list(entries: Self.abcEntry)) { directory in
            let run = try await verify("disc.iso", in: directory)
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output.contains("matches the pinned entry: Test disc 1.2"), "\(run.output)")
            #expect(run.output.contains("notes: scratch, 2026-10-25"), "\(run.output)")
        }
    }

    @Test
    func aFileNotInTheListSaysSoAndExitsOne() async throws {
        let other = #"{"sha256": "\#(String(repeating: "0", count: 64))", "name": "Other", "version": "9", "notes": "n"}"#
        try await withFixture(list: Self.list(entries: other)) { directory in
            let run = try await verify("disc.iso", in: directory)
            #expect(run.status == DriverVerifyStatus.noMatch, "\(run.combined)")
            #expect(run.output.contains("not in the pinned list"), "\(run.output)")
            #expect(run.output.contains(Self.abc), "\(run.output)")
        }
    }

    @Test
    func theShippedListParsesAndMatchesNothing() throws {
        let pins = try DriverPins.load(from: Self.repositoryRoot.appending(path: DriverPins.relativePath))
        #expect(pins.entries.isEmpty, "the owner adds the pins; the repository ships none")
        #expect(pins.entry(forDigest: Self.abc) == nil)
    }

    @Test
    func aMalformedListExitsSixtyFive() async throws {
        let bad = [
            "not json", Self.list(entries: #"{"sha256": "abc", "name": "n", "version": "v", "notes": "n"}"#),
            Self.list(entries: Self.abcEntry + "," + Self.abcEntry),
            Self.list(entries: #"{"sha256": "\#(Self.abc)", "name": "n", "version": "v", "notes": ""}"#),
            #"{"schema": 2, "entries": []}"#, #"{"schema": 1}"#,
        ]
        for text in bad {
            try await withFixture(list: text) { directory in
                let run = try await verify("disc.iso", in: directory)
                #expect(run.status == DriverVerifyStatus.listUnusable, "\(text): \(run.combined)")
                #expect(run.error.contains("malformed"), "\(run.error)")
            }
        }
        try await withFixture(list: nil) { directory in
            let run = try await verify("disc.iso", in: directory)
            #expect(run.status == DriverVerifyStatus.listUnusable, "a missing list: \(run.combined)")
        }
    }

    @Test
    func aMissingFileExitsSixtySix() async throws {
        try await withFixture(list: Self.list(entries: Self.abcEntry)) { directory in
            let run = try await verify("missing.iso", in: directory)
            #expect(run.status == DriverVerifyStatus.fileUnreadable, "\(run.combined)")
            #expect(run.error.contains("cannot read"), "\(run.error)")
        }
    }

    @Test
    func aDirectoryAndASymlinkLoopAreRefused() async throws {
        try await withFixture(list: Self.list(entries: Self.abcEntry)) { directory in
            try FileManager.default.createDirectory(at: directory.appending(path: "folder"), withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: directory.appending(path: "loop").path, withDestinationPath: "loop")
            let folder = try await verify("folder", in: directory)
            #expect(folder.status == DriverVerifyStatus.fileUnreadable, "\(folder.combined)")
            #expect(folder.error.contains("not a regular file"), "\(folder.error)")
            let loop = try await verify("loop", in: directory)
            #expect(loop.status == DriverVerifyStatus.fileUnreadable, "\(loop.combined)")
        }
    }

    @Test
    func theHelpSaysWhatItIsAndKeepsTheFileUntouched() async throws {
        try await withFixture(list: Self.list(entries: "")) { directory in
            let help = try await VMR.vmr(["windows", "drivers", "verify", "--help"], in: directory)
            // The help wraps its text, so compare the words.
            let words = help.output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            #expect(words.contains("Checks a driver disc you downloaded against the SHA-256 values pinned in this repository."), "\(words)")
            let before = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "disc.iso").path)
            _ = try await verify("disc.iso", in: directory)
            let after = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "disc.iso").path)
            #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        }
    }
}
