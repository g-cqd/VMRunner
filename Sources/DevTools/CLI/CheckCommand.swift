import ArgumentParser
import Foundation

struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Run the quality gate.",
        discussion: """
            Fast gate (no arguments): \(GateCatalog.fastSteps.map(\.name).joined(separator: " ")). With --full it also \
            runs \(GateCatalog.fullOnlySteps.map(\.name).joined(separator: " ")).

            Every selected step runs, even after a failure; each prints PASS or FAIL, and the exit status is \
            non-zero if any failed.

            Only one gate runs per checkout: a second `vmr check` exits at once with status 75 and names the pid of \
            the first (an exclusive lock on .build, released when the process ends).

            When GITHUB_STEP_SUMMARY names a file, a Markdown table of the steps (result, duration) is appended to \
            it, with the test counts, the coverage and the analyzer findings that the steps reported.

            Environment: COVERAGE_MIN (the coverage floor, default from .vmr.json or 55) and SWIFT_TEST_FLAGS \
            (extra flags for the plain `swift test` step).
            """
    )

    @OptionGroup var project: ProjectOptions

    @Flag(help: "Run the fast gate plus the sanitizers, the release build, the coverage gate and the benchmark gate.")
    var full = false

    @Flag(help: "Print the steps and exit.")
    var list = false

    @Argument(help: "Run only these steps, in this order (see --list).")
    var steps: [String] = []

    func validate() throws {
        if let unknown = steps.first(where: { GateCatalog.step(named: $0) == nil }) {
            throw ValidationError("unknown step '\(unknown)' (see --list)")
        }
        if full && !steps.isEmpty {
            throw ValidationError("--full and explicit steps are mutually exclusive")
        }
    }

    func run() async throws {
        if list {
            for step in GateCatalog.allSteps {
                Output.out(step.name)
            }
            return
        }
        try await perform {
            let root = try project.packageRoot()
            let selected =
                steps.isEmpty ? (full ? GateCatalog.allSteps : GateCatalog.fastSteps) : steps.compactMap(GateCatalog.step(named:))
            let environment = ProcessInfo.processInfo.environment
            let context = StepContext(
                root: root, config: try ProjectConfig.load(root: root), environment: environment,
                facts: GateFacts.collecting(environment: environment))
            return try await GateLock.hold(root: root) { await GateRunner.run(steps: selected, context: context) ? 0 : 1 }
        }
    }
}
