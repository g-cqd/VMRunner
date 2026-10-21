import Foundation

/// What a gate step runs against: the package root, its configuration and the environment.
struct StepContext: Sendable {
    let root: URL
    let config: ProjectConfig
    let environment: [String: String]

    /// Runs a command in the package root with its output streaming to this process's stdout and stderr.
    /// Throws when it exits non-zero.
    func run(_ executable: String, _ arguments: [String]) async throws {
        let spec = CommandSpec(executable: executable, arguments: arguments, workingDirectory: root)
        let result = try await ProcessRunner.run(spec, output: .inherit)
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
