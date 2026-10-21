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

            Environment: COVERAGE_MIN (the coverage floor, default from .vmr.json or 55) and SWIFT_TEST_FLAGS \
            (extra flags for the plain `swift test` step).
            """
    )

    @OptionGroup var project: ProjectOptions

    @Flag(help: "Run the fast gate plus the sanitizers, the release build and the coverage gate.")
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
            let context = StepContext(
                root: root, config: try ProjectConfig.load(root: root), environment: ProcessInfo.processInfo.environment)
            return await GateRunner.run(steps: selected, context: context) ? 0 : 1
        }
    }
}
