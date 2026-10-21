import Foundation
import Subprocess
import Synchronization

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

/// Runs child processes with swift-subprocess.
///
/// In `.inherit` mode the child writes straight to this process's stdout and stderr descriptors, so long outputs
/// (builds, test runs) stream without being buffered or copied. `.capture` collects both streams in memory, up to a
/// limit, and is meant for short outputs.
enum ProcessRunner {
    private static let captureLimit = 64 << 20
    /// SIGTERM first; swift-subprocess sends SIGKILL when the process is still running after this.
    private static let terminationGrace = Duration.seconds(5)

    static func run(_ spec: CommandSpec, output: OutputMode = .capture) async throws -> CommandResult {
        let environment = spec.effectiveEnvironment
        let executable = try ToolLocator.resolve(spec.executable, searchPath: environment["PATH"])
        guard let timeout = spec.timeout else {
            return try await launch(spec, executable: executable, environment: environment, mode: output)
        }

        // Cancelling the launch task makes swift-subprocess run the teardown sequence: SIGTERM, then SIGKILL.
        let expired = Expiry()
        return try await withThrowingTaskGroup(of: CommandResult?.self) { group in
            group.addTask {
                let result = try await launch(spec, executable: executable, environment: environment, mode: output)
                return CommandResult(
                    status: result.status,
                    standardOutput: result.standardOutput,
                    standardError: result.standardError,
                    timedOut: expired.hasFired
                )
            }
            group.addTask {
                // A cancelled sleep means the process finished first.
                if (try? await Task.sleep(for: timeout)) != nil { expired.fire() }
                return nil
            }
            var finished: CommandResult?
            for try await item in group {
                finished = item ?? finished
                group.cancelAll()
            }
            guard let finished else { throw ToolError("\(spec.executable) produced no result") }
            return finished
        }
    }

    private static func launch(
        _ spec: CommandSpec,
        executable: URL,
        environment: [String: String],
        mode: OutputMode
    ) async throws -> CommandResult {
        var options = PlatformOptions()
        options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: terminationGrace)]
        let child = Environment.custom(
            Dictionary(uniqueKeysWithValues: environment.map { (Environment.Key(stringLiteral: $0.key), $0.value) }))
        let directory = spec.workingDirectory.map { FilePath($0.path) }
        let program = Executable.path(FilePath(executable.path))
        let arguments = Arguments(spec.arguments)

        do {
            switch mode {
            case .inherit:
                let result = try await Subprocess.run(
                    program,
                    arguments: arguments,
                    environment: child,
                    workingDirectory: directory,
                    platformOptions: options,
                    output: .currentStandardOutput,
                    error: .currentStandardError
                )
                return CommandResult(status: status(of: result.terminationStatus), standardOutput: "", standardError: "", timedOut: false)
            case .capture:
                let result = try await Subprocess.run(
                    program,
                    arguments: arguments,
                    environment: child,
                    workingDirectory: directory,
                    platformOptions: options,
                    output: .string(limit: captureLimit),
                    error: .string(limit: captureLimit)
                )
                return CommandResult(
                    status: status(of: result.terminationStatus),
                    standardOutput: result.standardOutput,
                    standardError: result.standardError,
                    timedOut: false
                )
            }
        } catch let error as SubprocessError {
            throw ToolError("cannot run \(spec.executable): \(error)")
        }
    }

    /// The exit status, or 128 plus the signal number when a signal killed the process, as a shell reports it.
    private static func status(of termination: TerminationStatus) -> Int32 {
        switch termination {
        case .exited(let code): code
        case .signaled(let signal): 128 + signal
        }
    }
}

/// Set by the timer when the time limit passes.
private final class Expiry: Sendable {
    private let fired = Mutex(false)

    var hasFired: Bool { fired.withLock { $0 } }

    func fire() {
        fired.withLock { $0 = true }
    }
}
