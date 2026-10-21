import ArgumentParser
import Foundation

extension AnalyzerTool: ExpressibleByArgument {}

/// The tools a subcommand applies to (the defaults when none is named) and the checkout it works on.
struct AnalyzerSelection: ParsableArguments {
    @OptionGroup var project: ProjectOptions

    @Argument(help: "arcleak, dolly or deadwood.")
    var tools: [AnalyzerTool] = []

    /// Runs `action` with the service for this checkout and the selected tools, as a command body.
    func perform(
        defaultTools: [AnalyzerTool] = AnalyzerTool.allCases,
        _ action: (AnalyzerService, [AnalyzerTool]) async throws -> Int32
    ) async throws {
        try await DevTools.perform {
            let service = AnalyzerService(root: try project.packageRoot(), environment: ProcessInfo.processInfo.environment)
            return try await action(service, tools.isEmpty ? defaultTools : tools)
        }
    }
}

struct AnalyzersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyzers",
        abstract: "Run the pinned static analyzers over Sources and Tests.",
        discussion: """
            arcleak finds retain cycles, anchor leaks and premature releases (gate: --strict). dolly finds duplicate \
            code (gate: exact clones only, see .dolly.json). deadwood finds unreferenced declarations and dead \
            branches (gate: --strict, production mode). Their configuration is .<tool>.json and their accepted \
            findings are .<tool>-baseline.json.

            The releases are pinned in Scripts/analyzers.lock, downloaded into the git-ignored .tools/ and verified \
            against the SHA-256 pinned there before anything is run.

            Environment: ARCLEAK_BIN, DOLLY_BIN, DEADWOOD_BIN use your own binary instead of the pinned download; \
            ANALYZERS_DIR moves the download directory; VMR_ANALYZERS_BASE_URL takes the release archives from a \
            file: or https: directory instead of GitHub (they are still verified against the lock).

            Analyzer exit codes: 1 findings, 64 usage, 70 nothing analyzed, 74 write error, 78 bad configuration or \
            baseline. Only 1 means the code has findings; the others mean the gate itself is broken.
            """,
        subcommands: [Run.self, Install.self, Baseline.self, Versions.self, Pins.self],
        defaultSubcommand: Run.self
    )

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check the workflow pins, then analyze (the default). Exits 1 if any tool failed."
        )

        @OptionGroup var selection: AnalyzerSelection

        func run() async throws {
            try await selection.perform { service, tools in try await service.run(tools: tools) ? 0 : 1 }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download and verify the pinned releases without running them.")

        @OptionGroup var selection: AnalyzerSelection

        func run() async throws {
            try await selection.perform { service, tools in
                try await service.install(tools: tools)
                return 0
            }
        }
    }

    struct Baseline: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Accept the current findings of dolly and deadwood (or the named tools) into .<tool>-baseline.json.",
            discussion: "Only new findings fail the gate afterwards. Commit the result."
        )

        @OptionGroup var selection: AnalyzerSelection

        func run() async throws {
            try await selection.perform(defaultTools: AnalyzerTool.baselineDefaults) { service, tools in
                try await service.writeBaselines(tools: tools)
                return 0
            }
        }
    }

    struct Versions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the pinned versions.")

        @OptionGroup var project: ProjectOptions

        func run() async throws {
            try await perform {
                try AnalyzerService(root: try project.packageRoot(), environment: ProcessInfo.processInfo.environment).versions()
                return 0
            }
        }
    }

    struct Pins: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check that .github/workflows pin the same releases as Scripts/analyzers.lock."
        )

        @OptionGroup var project: ProjectOptions

        func run() async throws {
            try await perform {
                try AnalyzerService(root: try project.packageRoot(), environment: ProcessInfo.processInfo.environment).checkPins() ? 0 : 1
            }
        }
    }
}
