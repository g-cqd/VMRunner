import Foundation

/// Files only their owner can read, private from the moment they exist. The mode is given to `open`, so there is no moment
/// at which the file has the process's umask mode and no `chmod` after the fact.
enum PrivateFile {
    /// Creates `path`, which must not exist, mode 0600, without following a link at that name. The caller owns the handle.
    static func create(atPath path: String) throws -> FileHandle {
        // `open` gets a NUL-terminated copy of the path that outlives the call; O_EXCL makes it fail when the name exists
        // (a link included) and O_NOFOLLOW when the last component is a link.
        let descriptor = unsafe open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Puts `data` at `path` as a private file: it is written to `path + ".partial"`, created by ``create(atPath:)`` after
    /// any leftover of that name was removed, and then renamed over `path`, so a reader sees the old file or the new one and
    /// never half of one. The temporary is removed when anything fails.
    static func replace(_ path: String, with data: Data) throws {
        let temporary = path + ".partial"
        try? FileManager.default.removeItem(atPath: temporary)
        let handle = try create(atPath: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            throw error
        }
        // Both names are NUL-terminated copies that outlive the call.
        guard unsafe rename(temporary, path) == 0 else {
            let code = POSIXError.Code(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(atPath: temporary)
            throw POSIXError(code)
        }
    }
}
