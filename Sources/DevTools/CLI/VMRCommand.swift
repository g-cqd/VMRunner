import ArgumentParser
import Foundation

/// The `vmr` command line: the quality gate, the analyzers, the app bundle, the git hook.
struct VMRCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vmr",
        abstract: "The VMRunner developer tools: quality gate, static analyzers, app bundling, sandbox spike, git hooks.",
        discussion: """
            These commands replace the former shell and Python scripts. Run them with `swift run vmr <command>`, or \
            through the SwiftPM plugins: `swift package check`, `swift package analyzers`, `swift package build-app`.
            """,
        subcommands: [
            CheckCommand.self,
            AnalyzersCommand.self,
            BenchCommand.self,
            BuildAppCommand.self,
            SandboxSpikeCommand.self,
            SpikeSignCommand.self,
            SarifCommand.self,
            HooksCommand.self,
        ]
    )
}

/// The entry point of the `vmr` executable.
public enum CLI {
    /// Runs the command in `arguments` (`CommandLine.arguments`, program name first) and exits the process.
    ///
    /// Git runs a hook under the hook's name, and `vmr hooks install` links `.git/hooks/pre-commit` to this
    /// binary, so a program name of `pre-commit` means `vmr hooks pre-commit`.
    public static func main(arguments: [String]) async {
        let program = URL(fileURLWithPath: arguments.first ?? "vmr").lastPathComponent
        let rest = program == HookInstaller.hookName ? ["hooks", "pre-commit"] : Array(arguments.dropFirst())
        await VMRCommand.main(rest)
    }
}
