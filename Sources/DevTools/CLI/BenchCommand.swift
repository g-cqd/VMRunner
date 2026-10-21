import ArgumentParser
import Foundation

struct BenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Record the benchmark baseline that `vmr check bench` holds the benchmarks to.",
        discussion: """
            The benchmarks are the suites named *Benchmarks (tagged .bench); a plain `swift test` skips them. They run in \
            an optimized build, into .build-bench, and report to a file that `vmr` reads. The baseline is \(BenchBaseline.fileName), \
            committed beside .vmr.json: each figure has a value, a tolerance and whether it is enforced. Allocation counts are \
            exact; retired instructions have a few percent of tolerance; wall-clock rates are reported only.
            """,
        subcommands: [Record.self]
    )

    struct Record: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run the benchmarks and write their figures into \(BenchBaseline.fileName).",
            discussion: """
                Use it after a deliberate improvement, or a deliberate regression that you accept; commit the result. \
                The tolerance and enforcement of a figure already in the file are kept, and a figure the run no longer \
                reports is dropped.
                """
        )

        @OptionGroup var project: ProjectOptions

        func run() async throws {
            try await perform {
                let root = try project.packageRoot()
                let environment = ProcessInfo.processInfo.environment
                let context = StepContext(root: root, config: try ProjectConfig.load(root: root), environment: environment)
                return try await GateLock.hold(root: root) {
                    let results = try await BenchRun.measure(context)
                    let exists = FileManager.default.fileExists(atPath: BenchBaseline.url(root: root).path)
                    let existing = exists ? try BenchBaseline.load(root: root) : BenchBaseline(benchmarks: [:])
                    try existing.recorded(results).write(root: root)
                    Output.out("recorded \(results.count) figure(s) in \(BenchBaseline.fileName); commit it")
                    return 0
                }
            }
        }
    }
}
