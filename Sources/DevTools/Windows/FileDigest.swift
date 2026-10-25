import CryptoKit
import Foundation

/// The SHA-256 of a file the user named, read once, in chunks, and never modified.
enum FileDigest {
    /// How much of the file is in memory at a time: disc images are several hundred MiB.
    static let chunkBytes = 1 << 20

    /// The digest of the regular file at `url` as 64 lowercase hexadecimal digits.
    ///
    /// The file is opened read-only and checked through the descriptor it was opened with. A link is followed (a loop
    /// fails with `ELOOP`); a directory, a device or a pipe is refused.
    /// - Throws: a `ToolError` with status `DriverVerifyStatus.fileUnreadable`.
    static func sha256(ofFileAt url: URL) throws -> String {
        // `open` gets a NUL-terminated copy of the path that outlives the call; O_NONBLOCK keeps a pipe from blocking it.
        let descriptor = unsafe open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            // `strerror` returns a static, NUL-terminated message that is copied at once.
            let reason = unsafe String(cString: strerror(errno))
            throw ToolError("cannot read \(url.path): \(reason)", status: DriverVerifyStatus.fileUnreadable)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        // `info` is a local that outlives the call, which fills it.
        guard unsafe fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ToolError("\(url.path) is not a regular file", status: DriverVerifyStatus.fileUnreadable)
        }
        var hasher = SHA256()
        do {
            while true {
                let finished = try autoreleasepool {
                    guard let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty else { return true }
                    hasher.update(data: chunk)
                    return false
                }
                if finished { break }
            }
        } catch {
            throw ToolError("cannot read \(url.path): \(error.localizedDescription)", status: DriverVerifyStatus.fileUnreadable)
        }
        return hasher.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }
}
