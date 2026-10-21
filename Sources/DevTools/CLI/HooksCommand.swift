import ArgumentParser
import Foundation

struct HooksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hooks",
        abstract: "Install the git pre-commit hook, or run its checks.",
        subcommands: [Install.self, PreCommitCommand.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Link the repository's pre-commit hook to this vmr binary.",
            discussion: """
                Git then runs swift-format lint and SwiftLint on the staged Swift files before each commit. The link \
                points at the built binary, so every `swift build` updates the hook; after `swift package clean` it \
                dangles (git skips it with a hint) until you build again or re-run this command. Bypass the hook in \
                an emergency with `git commit --no-verify`.
                """
        )

        @OptionGroup var project: ProjectOptions

        func run() async throws {
            try await perform {
                guard let executable = Bundle.main.executableURL else { throw ToolError("cannot locate the vmr executable") }
                try await HookInstaller(git: Git(directory: project.workingDirectory()), executable: executable.standardizedFileURL)
                    .install()
                return 0
            }
        }
    }

    struct PreCommitCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: HookInstaller.hookName,
            abstract: "Run the pre-commit checks on the staged files. This is what git runs."
        )

        @OptionGroup var project: ProjectOptions

        func run() async throws {
            try await perform {
                let top = try await Git(directory: project.workingDirectory()).topLevel()
                return try await PreCommit.run(root: top, environment: ProcessInfo.processInfo.environment)
            }
        }
    }
}
