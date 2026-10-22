import CryptoKit
import Foundation

enum Checksums {
    /// Streams the file through the hash so a 26 GB IPSW never sits in memory. Cancelling the caller
    /// stops the read.
    static func hexDigest(of url: URL, algorithm: Checksum.Algorithm) async throws -> String {
        let work = Task.detached(priority: .utility) { try digest(of: url, algorithm: algorithm) }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    static func verify(_ url: URL, against checksum: Checksum) async throws {
        guard checksum.algorithm == .sha256 else { throw SetupError.weakChecksum(url.lastPathComponent) }
        let actual = try await hexDigest(of: url, algorithm: checksum.algorithm)
        guard actual.caseInsensitiveCompare(checksum.value) == .orderedSame else {
            throw SetupError.checksumMismatch(file: url.lastPathComponent, expected: checksum.value, actual: actual)
        }
    }

    /// Streams the file through the hash that `check`'s signature uses and verifies the signature over it, so a signed
    /// installer is proven by its own bytes. Cancelling the caller stops the read.
    /// - Throws: `SetupError.signatureRejected` naming `name` if the signature does not match.
    static func verify(_ url: URL, named name: String, signedBy check: PGP.Check) async throws {
        let work = Task.detached(priority: .utility) { try signedDigest(of: url, using: check) }
        let digest = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        do {
            try check.verify(digest)
        } catch {
            throw SetupError.signatureRejected(file: name, reason: error.localizedDescription)
        }
    }

    /// Opens `url` for reading if it is a regular file, and never through a symbolic link: the image cache is shared, so a
    /// planted link must not turn the verification of one file into the reading of another.
    /// - Throws: `SetupError.notARegularFile` for a link, a directory or a device; the POSIX error for anything else.
    static func openRegularFile(_ url: URL) throws -> FileHandle {
        // `open` gets a NUL-terminated copy of the path that outlives the call; O_NOFOLLOW makes it fail with ELOOP on a link.
        let descriptor = unsafe open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw code == ELOOP ? SetupError.notARegularFile(url.lastPathComponent) : POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        // `status` is a local that outlives the call, which fills it.
        guard unsafe fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            try? handle.close()
            throw SetupError.notARegularFile(url.lastPathComponent)
        }
        return handle
    }

    private static func signedDigest(of url: URL, using check: PGP.Check) throws -> PGP.Digest {
        let handle = try openRegularFile(url)
        defer { try? handle.close() }
        var digest = check.makeDigest()
        try forEachChunk(of: handle) { digest.update($0) }
        return digest
    }

    // 4 MiB chunks measured fastest for FileHandle reads (1 MiB: -16%, 16 MiB: -78% on an M3, 1 GB file).
    private static let chunkSize = 4 << 20

    /// Reads `handle` from where it stands to its end through one buffer of `chunkSize` bytes, reused for every read, and
    /// hands each filled part to `body`. Checks for cancellation before each read.
    private static func forEachChunk(of handle: FileHandle, _ body: (ArraySlice<UInt8>) throws -> Void) throws {
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        let descriptor = handle.fileDescriptor
        while true {
            try Task.checkCancellation()
            // `bytes` spans the whole buffer for the duration of the call; `read` writes at most `bytes.count` bytes into it.
            let count = buffer.withUnsafeMutableBytes { bytes in unsafe read(descriptor, bytes.baseAddress, bytes.count) }
            if count == 0 { return }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            try body(buffer[..<count])
        }
    }

    private static func digest(of url: URL, algorithm: Checksum.Algorithm) throws -> String {
        switch algorithm {
        case .sha256: try streamedDigest(of: url, using: SHA256.self)
        // SHA-1 cannot vouch for a file (`verify` refuses it first); nothing is hashed with it.
        case .refused: throw SetupError.weakChecksum(url.lastPathComponent)
        }
    }

    /// The lowercase hex digest of the file under `H`, read through `forEachChunk`.
    private static func streamedDigest<H: HashFunction>(of url: URL, using _: H.Type) throws -> String {
        let handle = try openRegularFile(url)
        defer { try? handle.close() }
        var hasher = H()
        try forEachChunk(of: handle) { hasher.update(data: $0) }
        return hasher.finalize().hexString
    }
}

/// The lowercase hexadecimal digits, indexed by their value.
private let hexDigits = Array("0123456789abcdef".utf8)

extension Sequence<UInt8> {
    /// Lowercase hexadecimal, two digits per byte.
    var hexString: String {
        var digits: [UInt8] = []
        digits.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            digits.append(hexDigits[Int(byte >> 4)])
            digits.append(hexDigits[Int(byte & 0x0F)])
        }
        // ASCII digits only
        return String(decoding: digits, as: UTF8.self)  // swiftlint:disable:this optional_data_string_conversion
    }
}
