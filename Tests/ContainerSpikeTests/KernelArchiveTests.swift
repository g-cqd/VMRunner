import Foundation
import Testing

@testable import ContainerSpikeCore

struct KernelArchiveTests {
    private func withFile<T>(_ contents: Data, _ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appending(path: "spike-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "file", directoryHint: .notDirectory)
        try contents.write(to: file)
        return try body(file)
    }

    private static let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test
    func theDigestOfAFileIsItsLowercaseSHA256() throws {
        let digest = try withFile(Data("abc".utf8)) { try KernelArchive.sha256(ofFileAt: $0) }
        #expect(digest == Self.abcDigest)
    }

    @Test
    func aFileLargerThanOneChunkIsHashedWhole() throws {
        // One million 'a' characters is the standard long test vector.
        let million = try withFile(Data(repeating: UInt8(ascii: "a"), count: 1_000_000)) { try KernelArchive.sha256(ofFileAt: $0) }
        #expect(million == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        // One byte more than a read chunk, so the loop runs twice. The expected value comes from Python's hashlib.
        let data = Data((0..<((1 << 20) + 1)).map { UInt8(truncatingIfNeeded: $0) })
        let chunked = try withFile(data) { try KernelArchive.sha256(ofFileAt: $0) }
        #expect(chunked == "607deb6eccbc844880b9d7b523751a4cdba0452727b885c74264bfe1fb7843e2")
    }

    @Test
    func verificationAcceptsTheRightDigestInAnyCaseAndRefusesAWrongOne() throws {
        let wrong = String(repeating: "0", count: 64)
        func failure(of file: URL, expected: String) -> KernelArchiveError? {
            do {
                try KernelArchive.verify(fileAt: file, expectedSHA256: expected)
                return nil
            } catch {
                return error
            }
        }
        let failures = try withFile(Data("abc".utf8)) { file in
            [Self.abcDigest, Self.abcDigest.uppercased(), wrong].map { failure(of: file, expected: $0) }
        }
        #expect(failures == [nil, nil, .checksumMismatch(expected: wrong, actual: Self.abcDigest)])
    }

    @Test
    func aMissingFileIsUnreadableNotAMismatch() {
        let missing = URL(fileURLWithPath: "/nonexistent/spike/kernel")
        #expect(throws: KernelArchiveError.unreadable(path: "/nonexistent/spike/kernel")) {
            try KernelArchive.verify(fileAt: missing, expectedSHA256: Self.abcDigest)
        }
    }

    @Test
    func thePinsAreWellFormed() throws {
        let hex = Set("0123456789abcdef")
        for digest in [KernelArchive.archiveSHA256, KernelArchive.imageSHA256] {
            #expect(digest.count == 64 && digest.allSatisfy(hex.contains), "\(digest)")
        }
        let url = try #require(URL(string: KernelArchive.urlString))
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        #expect(url.lastPathComponent == KernelArchive.fileName)
        let member = KernelArchive.memberPath.split(separator: "/")
        #expect(!member.contains(".."), "the member must stay inside the extraction directory")
        #expect(!KernelArchive.memberPath.hasPrefix("/"))
    }

    @Test
    func onlyTheOneMemberIsExtractedAndItLandsUnderTheStagingDirectory() {
        let archive = URL(fileURLWithPath: "/s/downloads/k.tar.xz")
        let staging = URL(fileURLWithPath: "/s/staging", isDirectory: true)
        #expect(
            KernelArchive.extractionArguments(archive: archive, directory: staging)
                == ["-x", "-J", "-f", "/s/downloads/k.tar.xz", "-C", "/s/staging", KernelArchive.memberPath])
        #expect(KernelArchive.extractedMember(in: staging).path == "/s/staging/opt/kata/share/kata-containers/vmlinux-6.12.28-153")
    }
}
