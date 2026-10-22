import Foundation

/// The exclusive lock that keeps two `vmr check` runs from sharing one checkout.
///
/// Two gates at once would fight over `.build` and the other scratch directories, so the second one fails at once and
/// names the first. The lock is `flock(2)` on the `.build` directory itself: it is released when the process exits or
/// dies, and `swift package clean` (which empties `.build` but keeps the directory) cannot replace it with a new file
/// that another gate would lock independently. The holder writes its pid to `.build/vmr-check.lock` for the message.
enum GateLock {
    /// `EX_TEMPFAIL` from `sysexits.h`: try again later.
    static let busyStatus: Int32 = 75
    static let holderFileName = "vmr-check.lock"

    /// How long a refused gate waits for the holder to record its pid.
    private static let holderAttempts = 10
    private static let holderPause = Duration.milliseconds(20)

    /// Runs `body` while holding the lock for the checkout at `root`. Throws a `ToolError` with `busyStatus` at once
    /// when another gate holds it.
    static func hold<Result>(root: URL, _ body: () async throws -> Result) async throws -> Result {
        let directory = root.appending(path: ".build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Unsafe only in signature: `open` takes the path as a C string, which Swift bridges from a String for the call.
        let descriptor = unsafe open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ToolError("cannot open \(directory.path): \(describe(errno))") }
        defer { release(descriptor) }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { throw ToolError("cannot lock \(directory.path): \(describe(errno))") }
            let holder = await holderPid(in: directory).map { "pid \($0)" } ?? "pid unknown"
            throw ToolError(
                "another `vmr check` is already running on this checkout (\(holder)); wait for it to finish, or stop it",
                status: busyStatus)
        }
        try? Data("\(getpid())\n".utf8).write(to: directory.appending(path: holderFileName))
        return try await body()
    }

    /// Unlocks and closes `descriptor`. `flock` locks the open file, not this descriptor: a copy that a concurrent spawn holds
    /// until its exec closes it would keep the lock after `close` alone, so the lock is released explicitly first.
    static func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// The pid in the holder file, once it names a live process (the holder writes it just after locking).
    private static func holderPid(in directory: URL) async -> Int32? {
        for _ in 0..<holderAttempts {
            let text = (try? String(contentsOf: directory.appending(path: holderFileName), encoding: .utf8)) ?? ""
            if let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, kill(pid, 0) == 0 || errno == EPERM {
                return pid
            }
            try? await Task.sleep(for: holderPause)
        }
        return nil
    }

    private static func describe(_ code: Int32) -> String {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
    }
}
