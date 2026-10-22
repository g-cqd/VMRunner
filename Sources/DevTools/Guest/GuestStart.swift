import Foundation
import GuestConsole
import VMHelperCore

/// `vmr guest start`: boots the fetched netboot image in a detached helper process and waits until its console shows a prompt.
///
/// The helper is the plain headless helper signed with the virtualization entitlement only (`vmr sandbox run --engine none`
/// is the same arrangement), started with a hard run-time limit; the scratch directory holds everything the run writes.
struct GuestStart {
    let scratch: GuestScratch
    let plan: GuestPlan
    /// The package root, where the helper is built and signed.
    let root: URL
    var configuration = AppBundler.Configuration.release
    /// A helper binary built already, signed here instead of building one.
    var prebuilt: URL?
    var maximumSeconds = GuestPlan.defaultMaximumSeconds
    var bootTimeout = Duration.seconds(180)

    /// What the start measured, in seconds since the helper was launched.
    struct Timing: Equatable {
        var consoleReady: Double?
        var running: Double?
        var prompt: Double?
    }

    /// The events a helper log holds, and the end of its text for an error message.
    struct HelperLog {
        let events: [HelperEvent]
        let tail: String

        init(text: String) {
            events = HelperEvent.parse(lines: text)
            tail = text.split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n")
        }

        func first(_ kind: HelperEvent.Kind) -> HelperEvent? { events.first { $0.event == kind } }
    }

    func run() async throws -> Int32 {
        try plan.validate()
        guard (1...GuestPlan.maximumSecondsLimit).contains(maximumSeconds) else {
            throw ToolError.usage("--max-seconds must be from 1 to \(GuestPlan.maximumSecondsLimit)")
        }
        let files = try NetbootFiles.existing(in: scratch)
        if let record = GuestProcess.read(from: scratch.pidFile), GuestProcess.isLive(record) {
            throw ToolError("a guest already runs from \(scratch.root.path) (pid \(record.pid)); stop it first: vmr guest stop")
        }
        try prepareRunDirectory()

        let descriptor = try plan.descriptor(files: files, scratch: scratch)
        try JSONEncoder.sorted.encode(descriptor).write(to: scratch.descriptorFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.descriptorFile.path)
        let loaded = try SandboxRun.load(descriptor: scratch.descriptorFile)

        let bundler = HelperBundler(root: root, configuration: configuration, prebuilt: prebuilt)
        let helper = try await bundler.plainHelper(from: try await bundler.binary())

        let started = ContinuousClock.now
        let pid = try GuestProcess.spawnDetached(
            executable: helper.path, arguments: ["--start", "--descriptor", loaded.path, "--run-seconds", "\(maximumSeconds)"],
            log: scratch.logFile)
        let record = GuestProcess.Record(pid: pid, executable: SandboxPath.realPath(helper.path) ?? helper.path)
        try GuestProcess.write(record, to: scratch.pidFile)
        Output.out("helper: pid \(pid), at most \(maximumSeconds) s, log \(scratch.logFile.path)")

        do {
            let timing = try await waitForPrompt(started: started, pid: pid)
            report(timing, socket: loaded.descriptor.console?.socket ?? scratch.socket.path)
            return 0
        } catch {
            _ = await GuestProcess.stop(record, grace: .seconds(5))
            if let socket = loaded.descriptor.console?.socket { try? FileManager.default.removeItem(atPath: socket) }
            try? FileManager.default.removeItem(at: scratch.pidFile)
            throw error
        }
    }

    // MARK: Steps

    private func prepareRunDirectory() throws {
        try GuestScratch.ensurePrivate(scratch.runDirectory)
        // What an earlier run left: its log is replaced, and a stale socket would make the bridge refuse to start.
        for leftover in [scratch.logFile, scratch.pidFile, scratch.socket] { try? FileManager.default.removeItem(at: leftover) }
    }

    /// Waits for the helper to report its console and the machine running, then for the console to show a prompt.
    private func waitForPrompt(started: ContinuousClock.Instant, pid: Int32) async throws -> Timing {
        var timing = Timing()
        let clock = ContinuousClock()
        let deadline = started + bootTimeout
        var socket: String?
        while socket == nil || timing.running == nil {
            let log = HelperLog(text: (try? String(contentsOf: scratch.logFile, encoding: .utf8)) ?? "")
            if let failure = log.first(.error) {
                throw ToolError("the helper failed: \(failure.message ?? "no message")")
            }
            if let ready = log.first(.consoleReady), socket == nil {
                socket = ready.message
                timing.consoleReady = (clock.now - started).asSeconds
            }
            if log.events.contains(where: { $0.event == .running }), timing.running == nil {
                timing.running = (clock.now - started).asSeconds
            }
            if socket != nil, timing.running != nil { break }
            guard GuestProcess.isRunning(pid) else {
                throw ToolError("the helper ended before the machine ran. Its log:\n\(log.tail)")
            }
            guard clock.now < deadline else {
                throw ToolError("the machine was not running after \(bootTimeout); the helper's log:\n\(log.tail)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let socket else { throw ToolError("the helper never reported its console socket") }
        let session = try ConsoleSession.connect(to: socket)
        defer { session.close() }
        do {
            let prompt = try session.waitForPrompt(timeout: max(deadline - clock.now, .seconds(1)))
            timing.prompt = (clock.now - started).asSeconds
            Output.out("console shows a \(prompt) prompt")
        } catch let error as ConsoleError {
            throw ToolError("the console showed no prompt: \(error)")
        }
        return timing
    }

    private func report(_ timing: Timing, socket: String) {
        func seconds(_ value: Double?) -> String { value.map { "\($0.formatted(.number.precision(.fractionLength(2)))) s" } ?? "never" }
        Output.out("console socket: \(socket)")
        Output.out(
            "timing from launch: console ready \(seconds(timing.consoleReady)), machine running \(seconds(timing.running)), "
                + "prompt \(seconds(timing.prompt))"
        )
        Output.out("run: vmr guest exec \(socket) -- uname -a")
    }
}

extension JSONEncoder {
    /// Stable, readable output for files people may open.
    fileprivate static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension Duration {
    var asSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
