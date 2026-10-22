import Foundation

/// The helper process of a running guest: started detached, recorded in a pid file, stopped by signal.
enum GuestProcess {
    /// What the pid file holds: the process and the program it was started as, so that a pid that has since been given to
    /// another program is never signalled.
    struct Record: Equatable {
        let pid: Int32
        let executable: String

        var text: String { "\(pid)\n\(executable)\n" }

        init(pid: Int32, executable: String) {
            self.pid = pid
            self.executable = executable
        }

        init?(text: String) {
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            guard lines.count == 2, let pid = Int32(lines[0]), pid > 1, lines[1].hasPrefix("/") else { return nil }
            self.init(pid: pid, executable: lines[1])
        }
    }

    // MARK: Starting

    /// Starts `executable` in a session of its own, so that it outlives this command and its terminal, with standard input
    /// read from `standardInput` (closed when it is nil) and standard output and error appended to `log` (created 0600).
    /// Returns the pid.
    static func spawnDetached(executable: String, arguments: [String], log: URL, standardInput: URL? = nil) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        // The initialisers fill structures the later calls and `posix_spawn` read; both are destroyed before returning.
        unsafe posix_spawn_file_actions_init(&actions)
        unsafe posix_spawnattr_init(&attributes)
        defer {
            unsafe posix_spawn_file_actions_destroy(&actions)
            unsafe posix_spawnattr_destroy(&attributes)
        }
        // A named pipe is opened for reading and writing, so that it never reports the end of its input when a writer leaves.
        unsafe posix_spawn_file_actions_addopen(
            &actions, 0, standardInput?.path ?? "/dev/null", standardInput == nil ? O_RDONLY : O_RDWR, 0)
        unsafe posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        unsafe posix_spawn_file_actions_adddup2(&actions, 1, 2)
        // A session of its own, no descriptor of this process inherited beyond the three above, and every signal back at its
        // default and unblocked: a parent that ignores SIGTERM (a job runner's shell does) must not make the helper unstoppable.
        var everySignal = sigset_t()
        var noSignal = sigset_t()
        unsafe sigfillset(&everySignal)
        unsafe sigemptyset(&noSignal)
        unsafe posix_spawnattr_setsigdefault(&attributes, &everySignal)
        unsafe posix_spawnattr_setsigmask(&attributes, &noSignal)
        unsafe posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let argv = unsafe ([executable] + arguments).map { unsafe strdup($0) }
        let environment = ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG"].compactMap { name in
            ProcessInfo.processInfo.environment[name].map { "\(name)=\($0)" }
        }
        let envp = unsafe environment.map { unsafe strdup($0) }
        defer {
            for unsafe pointer in unsafe argv + envp { unsafe free(pointer) }
        }
        var pid: pid_t = 0
        let status = unsafe (argv + [nil]).withUnsafeBufferPointer { argvBuffer in
            unsafe (envp + [nil]).withUnsafeBufferPointer { envBuffer in
                // Both arrays are NULL-terminated and outlive the call.
                unsafe posix_spawn(&pid, executable, &actions, &attributes, argvBuffer.baseAddress, envBuffer.baseAddress)
            }
        }
        guard status == 0 else {
            throw ToolError("cannot start \(executable): \(unsafe String(cString: strerror(status)))")
        }
        return pid
    }

    // MARK: Pid file

    static func write(_ record: Record, to file: URL) throws {
        try Data(record.text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func read(from file: URL) -> Record? {
        guard let data = FileManager.default.contents(atPath: file.path), let text = String(bytes: data, encoding: .utf8) else {
            return nil
        }
        return Record(text: text)
    }

    // MARK: Inspecting

    static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The program a process runs, or `nil` when there is no such process.
    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = unsafe proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    /// Whether `record` still names a live process that runs the program it was started as.
    static func isLive(_ record: Record) -> Bool {
        isRunning(record.pid) && executablePath(of: record.pid).map { $0 == record.executable } == true
    }

    // MARK: Stopping

    enum StopOutcome: Equatable {
        case notRunning
        case stopped
        /// SIGTERM was ignored for the whole grace period and SIGKILL was needed.
        case killed
    }

    /// Ends the process in `record` with SIGTERM, then SIGKILL after `grace`, and waits until it is gone.
    static func stop(_ record: Record, grace: Duration) async -> StopOutcome {
        guard isLive(record) else { return .notRunning }
        kill(record.pid, SIGTERM)
        if await waitUntilGone(record, within: grace) { return .stopped }
        kill(record.pid, SIGKILL)
        _ = await waitUntilGone(record, within: .seconds(5))
        return .killed
    }

    private static func waitUntilGone(_ record: Record, within limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while isLive(record) {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}
