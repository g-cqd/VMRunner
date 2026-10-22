import Foundation
import Synchronization
import VMHelperCore

/// How the helper is launched under an engine: the program to run, the arguments that come before the helper's own, and the
/// helper binary that ends up running.
struct SandboxLaunch: Equatable {
    let executable: String
    let leadingArguments: [String]
    let helperPath: String

    static let sandboxExec = "/usr/bin/sandbox-exec"

    /// `none` runs the signed helper itself, `seatbelt` runs it under `sandbox-exec -f profile`, `app-sandbox` runs the
    /// executable inside the signed bundle (the sandbox comes from its entitlements).
    static func make(engine: SandboxEngine, helper: String, profile: String?) -> Self {
        switch engine {
        case .none, .appSandbox: Self(executable: helper, leadingArguments: [], helperPath: helper)
        case .seatbelt: Self(executable: sandboxExec, leadingArguments: ["-f", profile ?? "", helper], helperPath: helper)
        }
    }

    func command(mode: SandboxPhase.Mode, descriptorPath: String, runSeconds: Int, timeout: Duration) -> CommandSpec {
        var arguments = leadingArguments + [mode.flag, "--descriptor", descriptorPath]
        if mode == .start { arguments += ["--run-seconds", "\(runSeconds)"] }
        return CommandSpec(executable: executable, arguments: arguments, timeout: timeout)
    }
}

extension ToolError {
    /// A helper failure from reading the descriptor, reported with the helper's own status.
    init(_ failure: HelperFailure) {
        self.init(failure.message, status: failure.exitStatus)
    }
}

/// `vmr sandbox run`: launches the helper under one engine, once to probe, once to validate and, when asked, once to
/// boot, then reads each launch's sandbox denials from the unified log and prints a report.
struct SandboxRun {
    struct Options {
        var engine: SandboxEngine
        var level: SandboxLevel
        var descriptor: URL
        /// Start the virtual machine. Only the owner does; agents and CI never do.
        var boot = false
        var runSeconds = SandboxRun.defaultRunSeconds
        var configuration = AppBundler.Configuration.release
        var prebuilt: URL?
    }

    static let defaultRunSeconds = 30

    /// How long the log is given to catch up with a refusal before each read, and how many reads it gets.
    static let logGrace = Duration.seconds(2)
    static let logReads = 5
    static let phaseTimeout = Duration.seconds(120)

    let root: URL
    let options: Options

    private var bundler: HelperBundler { HelperBundler(root: root, configuration: options.configuration, prebuilt: options.prebuilt) }

    /// Runs the phases and prints the report; the status is non-zero when any launch of the helper failed.
    func run() async throws -> Int32 {
        let loaded = try Self.load(descriptor: options.descriptor)
        let grants = try Self.grants(for: loaded, level: options.level)
        let launch = try await prepare(grants: grants)
        Output.out("")

        var phases: [SandboxPhase] = []
        let modes: [SandboxPhase.Mode] = options.boot ? [.probe, .dryRun, .start] : [.probe, .dryRun]
        for mode in modes {
            phases.append(try await runPhase(mode, launch: launch, descriptorPath: loaded.path))
        }
        for line in SandboxReport.lines(
            engine: options.engine, level: options.level, descriptorPath: loaded.path, helperPath: launch.helperPath, phases: phases)
        {
            Output.out(line)
        }
        return phases.allSatisfy { $0.status == 0 } ? 0 : 1
    }

    // MARK: Inputs

    /// The descriptor, with its paths resolved, and the real path it was read from.
    static func load(descriptor url: URL) throws -> (descriptor: HelperDescriptor, path: String) {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw ToolError("cannot read the descriptor \(url.path)") }
        do {
            return (try HelperDescriptor.parse(data).canonicalized(), SandboxPath.realPath(url.path) ?? url.path)
        } catch let failure as HelperFailure {
            throw ToolError(failure)
        }
    }

    static func grants(for loaded: (descriptor: HelperDescriptor, path: String), level: SandboxLevel) throws -> SandboxGrants {
        do {
            return try SandboxGrants(descriptor: loaded.descriptor, descriptorPath: loaded.path, level: level)
        } catch let failure as HelperFailure {
            throw ToolError(failure)
        }
    }

    // MARK: Preparing the engine

    private func prepare(grants: SandboxGrants) async throws -> SandboxLaunch {
        let binary = try await bundler.binary()
        switch options.engine {
        case .none:
            let helper = try await bundler.plainHelper(from: binary)
            return .make(engine: .none, helper: helper.path, profile: nil)
        case .seatbelt:
            let helper = try await bundler.plainHelper(from: binary)
            let canonical = SandboxPath.realPath(helper.path) ?? helper.path
            let profile = bundler.workDirectory.appending(path: "seatbelt-\(options.level.rawValue).sb")
            do {
                try SeatbeltProfile.generate(grants: grants, helperExecutable: canonical).write(
                    to: profile, atomically: true, encoding: .utf8)
            } catch let failure as HelperFailure {
                throw ToolError(failure)
            }
            Output.out("profile: \(profile.path)")
            return .make(engine: .seatbelt, helper: canonical, profile: profile.path)
        case .appSandbox:
            let executable = try await bundler.appSandboxHelper(from: binary, grants: grants)
            return .make(engine: .appSandbox, helper: executable.path, profile: nil)
        }
    }

    // MARK: Phases

    private func runPhase(_ mode: SandboxPhase.Mode, launch: SandboxLaunch, descriptorPath: String) async throws -> SandboxPhase {
        let timeout = mode == .start ? Self.phaseTimeout + .seconds(options.runSeconds) : Self.phaseTimeout
        let spec = launch.command(mode: mode, descriptorPath: descriptorPath, runSeconds: options.runSeconds, timeout: timeout)
        Output.out("running \(mode.rawValue) under \(options.engine.rawValue)/\(options.level.rawValue)")

        let began = ContinuousClock.now
        var events: [HelperEvent] = []
        var console: SandboxPhase.Console?
        let result: CommandResult
        if mode == .start {
            // The guest's console and the helper's events arrive together; the console lines are the ones that are not events.
            let recorder = LineRecorder()
            result = try await ProcessRunner.run(spec, output: .stream { recorder.record($0) })
            (events, console) = Self.separate(recorder.snapshot)
        } else {
            result = try await ProcessRunner.run(spec)
            events = HelperEvent.parse(lines: result.standardOutput)
        }
        let seconds = (ContinuousClock.now - began).inSeconds
        return SandboxPhase(
            mode: mode, status: result.status, timedOut: result.timedOut, events: events, console: console,
            denials: await denials(pid: events.first?.pid, since: began), seconds: seconds)
    }

    /// Splits recorded lines into the helper's events and a summary of everything else, which is the guest's console.
    static func separate(_ recorded: [(text: String, at: ContinuousClock.Instant)]) -> ([HelperEvent], SandboxPhase.Console) {
        var events: [HelperEvent] = []
        var console = SandboxPhase.Console(lines: 0, firstLineAfterBooting: nil)
        var booting: ContinuousClock.Instant?
        for (text, at) in recorded {
            if let event = HelperEvent.parse(lines: text).first {
                events.append(event)
                if event.event == .booting { booting = at }
            } else {
                console.lines += 1
                if let booting, console.firstLineAfterBooting == nil {
                    console.firstLineAfterBooting = (at - booting).inSeconds
                }
            }
        }
        return (events, console)
    }

    /// The denials the log holds for `pid`, or `nil` when there is no pid to ask about or the log could not be read.
    ///
    /// The log catches up with a refusal after a delay that varies, so it is read every `logGrace` until two reads in a row
    /// agree, at most `logReads` times.
    private func denials(pid: Int32?, since began: ContinuousClock.Instant) async -> [SandboxDenial]? {
        guard let pid else { return nil }
        var previous: [SandboxDenial]?
        for _ in 0..<Self.logReads {
            try? await Task.sleep(for: Self.logGrace)
            let seconds = Int((ContinuousClock.now - began).inSeconds) + 5
            let spec = CommandSpec(executable: "/usr/bin/log", arguments: SandboxLog.arguments(pid: pid, lastSeconds: seconds))
            guard let result = try? await ProcessRunner.run(spec), result.succeeded else { return previous }
            let current = SandboxLog.parse(result.standardOutput, pid: pid)
            if current == previous { return current }
            previous = current
        }
        return previous
    }
}

extension Duration {
    /// The duration in seconds, with its fraction.
    fileprivate var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// The lines of a launch's output, each with the moment it arrived. Two tasks (standard output and standard error) write.
private final class LineRecorder: Sendable {
    private let lines = Mutex<[(text: String, at: ContinuousClock.Instant)]>([])

    func record(_ line: String) {
        lines.withLock { $0.append((line, ContinuousClock.now)) }
    }

    var snapshot: [(text: String, at: ContinuousClock.Instant)] { lines.withLock { $0 } }
}
