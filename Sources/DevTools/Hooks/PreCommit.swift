import Foundation

/// The fast checks git runs before a commit: swift-format lint and SwiftLint on the staged Swift files only.
/// The full gate is `vmr check`. Bypass in an emergency with `git commit --no-verify`.
enum PreCommit {
    /// Returns the hook's exit status: 0 lets the commit proceed.
    static func run(root: URL, environment: [String: String]) async throws -> Int32 {
        let staged = try await Git(directory: root).stagedPaths().filter { $0.hasSuffix(".swift") }
        guard !staged.isEmpty else { return 0 }

        Output.out("pre-commit: swift-format lint (\(staged.count) file(s))")
        Output.out("pre-commit: swiftlint (\(staged.count) file(s))")
        let swiftFormat = try await ToolLocator.swiftFormat(environment: environment)
        async let format = capture(swiftFormat, ["lint", "--strict"] + staged, root: root)
        async let lint = lintWithSwiftLint(staged, root: root, environment: environment)

        var failed = false
        for (name, outcome) in [("swift-format", await format), ("swiftlint", await lint)] {
            switch outcome {
            case .success(let result):
                forward(result)
                failed = failed || !result.succeeded
            case .failure(let error):
                Output.err("pre-commit: \(name): \(error)")
                failed = true
            }
        }
        if failed {
            Output.err("pre-commit: checks failed; fix the findings above or run `swift run vmr check` for the full picture")
            return 1
        }
        return 0
    }

    /// The pinned SwiftLint (installed on first use) over the staged files; a missing or refused install is a failure to report.
    private static func lintWithSwiftLint(_ staged: [String], root: URL, environment: [String: String]) async -> Result<
        CommandResult, any Error
    > {
        do {
            let swiftlint = try await ToolLocator.swiftlint(root: root, environment: environment)
            return await capture(swiftlint, ["lint", "--quiet", "--force-exclude"] + staged, root: root)
        } catch {
            return .failure(error)
        }
    }

    private static func capture(_ executable: String, _ arguments: [String], root: URL) async -> Result<CommandResult, any Error> {
        do {
            return .success(try await ProcessRunner.run(CommandSpec(executable: executable, arguments: arguments, workingDirectory: root)))
        } catch {
            return .failure(error)
        }
    }

    private static func forward(_ result: CommandResult) {
        if !result.standardOutput.isEmpty { Output.out(result.standardOutput.trimmingCharacters(in: .newlines)) }
        if !result.standardError.isEmpty { Output.err(result.standardError.trimmingCharacters(in: .newlines)) }
    }
}
