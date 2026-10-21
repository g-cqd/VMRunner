import CryptoKit
import Foundation
import Testing

@testable import VMRunner

/// The vendor signs the installer itself (Alpine): the signature is vetted before the download and checked against the file's
/// own bytes after it. A throwaway key signs a stand-in installer, so every case runs without a network or a large file.
struct ImageSignatureTests {
    private let signer: TestSigner
    private let host = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/"
    private let name = "alpine-virt-9.9.9-aarch64.iso"

    init() throws { signer = try SharedSigner.get() }

    private struct SignedFile {
        var file: URL
        var check: PGP.Check
        var bytes: Data
    }

    /// A file of `size` bytes in a scratch directory (the caller removes it), and the check for its signature.
    private func signedFile(size: Int, in directory: URL) throws -> SignedFile {
        let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ ($0 >> 12)) })
        let file = directory.appending(path: name)
        try bytes.write(to: file)
        let armored = try signer.detachedSignature(over: Array(bytes))
        return SignedFile(file: file, check: try PGP.Check.detached(armored, keys: [signer.key], now: pgpTestNow), bytes: bytes)
    }

    @Test(arguments: [0, 1, (4 << 20) - 1, 4 << 20, (4 << 20) + 1, 9 << 20])
    func aSignedFileOfAnySizeVerifiesWhenStreamed(size: Int) async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let signed = try signedFile(size: size, in: directory)
        try await Checksums.verify(signed.file, named: name, signedBy: signed.check)
    }

    @Test(arguments: [0, 4 << 20, (9 << 20) - 1])
    func aFlippedByteInAnyChunkFails(offset: Int) async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let signed = try signedFile(size: 9 << 20, in: directory)
        var damaged = signed.bytes
        damaged[offset] ^= 0x01
        try damaged.write(to: signed.file)

        await #expect {
            try await Checksums.verify(signed.file, named: name, signedBy: signed.check)
        } throws: { error in
            guard case SetupError.signatureRejected(let file, let reason) = error else { return false }
            return file == name && reason.contains("does not match")
        }
    }

    @Test func aTruncatedOrExtendedFileFails() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let signed = try signedFile(size: 100_000, in: directory)
        for damaged in [signed.bytes.dropLast(), signed.bytes + [0]] {
            try Data(damaged).write(to: signed.file)
            await #expect(throws: SetupError.self) { try await Checksums.verify(signed.file, named: name, signedBy: signed.check) }
        }
    }

    @Test func theChecksumAndTheSignatureMustBothPass() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let signed = try signedFile(size: 5000, in: directory)
        let matching = Checksum(algorithm: .sha256, value: SHA256.hash(data: signed.bytes).hexString)
        let other = Checksum(algorithm: .sha256, value: String(repeating: "0", count: 64))

        try await ImageStore.verify(signed.file, named: name, checksum: matching, signature: signed.check)
        try await ImageStore.verify(signed.file, named: name, checksum: nil, signature: signed.check)
        await #expect(throws: SetupError.self, "a good signature does not excuse a wrong checksum") {
            try await ImageStore.verify(signed.file, named: name, checksum: other, signature: signed.check)
        }
        let anotherFile = try signer.detachedSignature(over: Array("another installer".utf8))
        let wrongSignature = try PGP.Check.detached(anotherFile, keys: [signer.key], now: pgpTestNow)
        await #expect(throws: SetupError.self, "a good checksum does not excuse a wrong signature") {
            try await ImageStore.verify(signed.file, named: name, checksum: matching, signature: wrongSignature)
        }
    }

    @Test func aCachedFileThatFailsItsSignatureIsDeletedSoItDownloadsAgain() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let signed = try signedFile(size: 5000, in: directory)

        #expect(
            try await ImageStore.validCachedFile(at: signed.file, checksum: nil, signature: signed.check, job: SetupJob()) == signed.file)

        try Data("replaced after the download".utf8).write(to: signed.file)
        let reused = try await ImageStore.validCachedFile(at: signed.file, checksum: nil, signature: signed.check, job: SetupJob())
        #expect(reused == nil)
        #expect(!FileManager.default.fileExists(atPath: signed.file.path), "a file that fails its signature is never left to be reused")
    }

    // MARK: Vetting before the download

    private func mirror(signature: [UInt8]?) -> FixtureMirror {
        var files: [String: Data] = [:]
        if let signature { files[host + name + ".asc"] = Data(signature) }
        return FixtureMirror(binary: files)
    }

    private var trust: SignedImageTrust { SignedImageTrust(suffix: "asc", keys: [signer.pinned]) }

    private func vouch(_ mirror: FixtureMirror, now: Date = pgpTestNow) async throws -> VouchedChecksum {
        let image = try #require(URL(string: host + name))
        return try await trust.vouch(
            for: Data("checksums".utf8), at: URL(filePath: "/unused/\(name).sha256"), image: image, now: now, fetch: mirror.fetch)
    }

    @Test func theSignatureIsFetchedNextToTheInstallerAndVettedBeforeTheDownload() async throws {
        let armored = try signer.detachedSignature(over: Array("the installer".utf8))
        let mirror = mirror(signature: armored)
        let vouched = try await vouch(mirror)
        #expect(vouched.text == "checksums")
        #expect(vouched.imageSignature?.key == signer.key)
        #expect(mirror.requests == [FixtureMirror.Request(url: host + name + ".asc", limit: PGP.maximumSignatureSize)])
    }

    @Test func aMissingOrUntrustedSignatureStopsBeforeTheDownload() async throws {
        let impostor = try TestSigner()
        let wrongKey = try impostor.detachedSignature(over: Array("the installer".utf8))
        for (name, armored) in [("missing", nil), ("another key", wrongKey), ("garbage", Array("garbage".utf8))] as [(String, [UInt8]?)] {
            await #expect(throws: SetupError.self, "\(name)") { try await vouch(mirror(signature: armored)) }
        }
        let futureSigned = try signer.detachedSignature(over: [], SignatureDraft(created: 1_799_999_999))
        await #expect(throws: SetupError.self, "made after the clock says") {
            try await vouch(mirror(signature: futureSigned), now: Date(timeIntervalSince1970: 1_750_000_000))
        }
    }
}
