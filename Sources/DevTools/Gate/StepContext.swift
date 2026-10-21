import Foundation

/// What a gate step runs against: the package root, its configuration and the environment.
struct StepContext: Sendable {
    let root: URL
    let config: ProjectConfig
    let environment: [String: String]
    /// Collects the figures for the job summary; nil when no summary was asked for, and then nothing is streamed.
    var facts: GateFacts?
    /// The step this context was made for (`scoped(to:)`).
    var step = ""

    func scoped(to step: String) -> Self {
        var copy = self
        copy.step = step
        return copy
    }

    private var outputMode: OutputMode {
        guard let facts else { return .inherit }
        let step = step
        return .stream { facts.observe($0, step: step) }
    }

    /// Runs a command in the package root with its output streaming to this process's stdout and stderr (line by line
    /// when a job summary is being collected).
    /// Throws when it exits non-zero.
    func run(_ executable: String, _ arguments: [String]) async throws {
        let spec = CommandSpec(executable: executable, arguments: arguments, workingDirectory: root)
        let result = try await ProcessRunner.run(spec, output: outputMode)
        guard result.succeeded else { throw Self.failure(executable, arguments, result) }
    }

    /// Runs a command in the package root and returns its standard output. For short outputs only.
    func capture(_ executable: String, _ arguments: [String]) async throws -> String {
        let spec = CommandSpec(executable: executable, arguments: arguments, workingDirectory: root)
        let result = try await ProcessRunner.run(spec, output: .capture)
        guard result.succeeded else {
            Output.err(result.standardError)
            throw Self.failure(executable, arguments, result)
        }
        return result.standardOutput
    }

    private static func failure(_ executable: String, _ arguments: [String], _ result: CommandResult) -> ToolError {
        let command = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments.prefix(2)).joined(separator: " ")
        return ToolError("`\(command)` exited with status \(result.status)", status: result.status)
    }
}
