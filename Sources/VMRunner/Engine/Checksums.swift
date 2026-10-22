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
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(chunk)
        }
        return digest
    }

    // 4 MiB chunks measured fastest for FileHandle reads (1 MiB: -16%, 16 MiB: -78% on an M3, 1 GB file).
    private static let chunkSize = 4 << 20

    private static func digest(of url: URL, algorithm: Checksum.Algorithm) throws -> String {
        let handle = try openRegularFile(url)
        defer { try? handle.close() }
        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().hexString
        case .sha1:
            var hasher = Insecure.SHA1()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().hexString
        }
    }
}

extension Sequence<UInt8> {
    /// Lowercase hexadecimal, two digits per byte.
    var hexString: String {
        map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
    }
}
