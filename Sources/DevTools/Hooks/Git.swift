import Foundation

/// Thin wrapper over the `git` command line, run inside one working tree.
struct Git: Sendable {
    let directory: URL

    /// The trimmed standard output of `git <arguments>`; throws with git's message when it fails.
    func output(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run(CommandSpec(executable: "git", arguments: arguments, workingDirectory: directory))
        guard result.succeeded else {
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolError("git \(arguments.prefix(2).joined(separator: " ")) failed\(message.isEmpty ? "" : ": \(message)")")
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The working tree's top-level directory.
    func topLevel() async throws -> URL {
        do {
            return URL(fileURLWithPath: try await output(["rev-parse", "--show-toplevel"]), isDirectory: true)
        } catch {
            throw ToolError("\(directory.path) is not a git repository")
        }
    }

    /// Paths of files that are added, copied, modified or renamed in the index.
    func stagedPaths() async throws -> [String] {
        let result = try await ProcessRunner.run(
            CommandSpec(
                executable: "git",
                arguments: ["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"],
                workingDirectory: directory
            )
        )
        guard result.succeeded else { throw ToolError("git diff --cached failed: \(result.standardError)") }
        return result.standardOutput.split(separator: "\0").map(String.init)
    }
}
