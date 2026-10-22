import Foundation
import VMHelperCore

/// `vmr guest policy`: puts a new network policy into a running guest whose network is filtered, without restarting it.
///
/// The new file replaces the one the descriptor names (the helper reads that path), then a `policy` command goes down the
/// pipe the helper reads as standard input, and the helper's `policy` event in its log says whether it took.
struct GuestPolicy {
    let scratch: GuestScratch
    let file: URL
    var terminatingOpenFlows = true
    var timeout = Duration.seconds(10)

    /// What the helper answered.
    struct Answer: Equatable {
        let applied: Bool
        let message: String
    }

    func run() async throws -> Answer {
        let record = try runningHelper()
        try requireFilteredNetwork()
        let policy = try GuestPlan.policyText(of: file)

        // The mark in the log is taken before the command, so an answer to an earlier command is never read as this one's.
        let mark = GuestLogReader(file: scratch.logFile).currentEnd
        try policy.write(to: scratch.policyFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.policyFile.path)
        try send(HelperCommand.reloadPolicy(terminatingOpenFlows: terminatingOpenFlows))

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let answer = GuestLogReader(file: scratch.logFile).events(after: mark).first(where: { $0.event == .policy }) {
                return Answer(applied: answer.check == "applied", message: answer.message ?? "")
            }
            guard GuestProcess.isLive(record) else { throw ToolError("the helper (pid \(record.pid)) ended before it answered") }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ToolError("the helper did not answer the policy command within \(timeout); see \(scratch.logFile.path)")
    }

    private func runningHelper() throws -> GuestProcess.Record {
        guard let record = GuestProcess.read(from: scratch.pidFile), GuestProcess.isLive(record) else {
            throw ToolError("no guest is running from \(scratch.root.path)")
        }
        return record
    }

    private func requireFilteredNetwork() throws {
        let data = try Data(contentsOf: scratch.descriptorFile)
        let descriptor = try JSONDecoder().decode(HelperDescriptor.self, from: data)
        guard descriptor.network == .filtered else {
            throw ToolError(
                "this guest was started with the \(descriptor.network.rawValue) network; start it with --net filtered to change its policy")
        }
    }

    /// Writes one command line to the helper's pipe. The helper holds the pipe open for reading and writing, so opening it
    /// for writing does not wait; if nobody holds it the open fails at once.
    private func send(_ command: HelperCommand) throws {
        let descriptor = unsafe open(scratch.commandPipe.path, O_WRONLY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw ToolError("cannot open the helper's command pipe \(scratch.commandPipe.path): errno \(errno)")
        }
        defer { close(descriptor) }
        let bytes = Array((command.line + "\n").utf8)
        let written = bytes.withUnsafeBytes { unsafe write(descriptor, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw ToolError("cannot write to the helper's command pipe: errno \(errno)") }
    }
}

/// The events in a helper's log, read from a byte offset on.
struct GuestLogReader {
    let file: URL

    /// How much the log holds now.
    var currentEnd: Int {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    }

    /// The events written after the first `offset` bytes.
    func events(after offset: Int) -> [HelperEvent] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil, let data = try? handle.readToEnd() else { return [] }
        return HelperEvent.parse(lines: String(bytes: data, encoding: .utf8) ?? "")
    }

    /// Every event in the log.
    var allEvents: [HelperEvent] { events(after: 0) }
}
