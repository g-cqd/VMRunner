import Foundation

extension GateSteps {
    /// The benchmark figures must not regress against `.vmr-bench.json`. A figure that got better tells you to re-record the
    /// baseline (`vmr bench record`), so the improvement becomes the new floor.
    @Sendable
    static func bench(_ context: StepContext) async throws {
        let baseline = try BenchBaseline.load(root: context.root)
        let comparisons = Bench.compare(try await BenchRun.measure(context), against: baseline)
        for comparison in comparisons {
            Output.out(comparison.line)
        }
        let improved = comparisons.filter { $0.verdict == .improved }.count
        if improved > 0 {
            let command = BenchBaseline.recordCommand
            Output.out("bench: \(improved) figure(s) improved beyond their tolerance; lock them in with `\(command)` and commit")
        }
        let failures = comparisons.filter(\.fails)
        guard failures.isEmpty else {
            let names = failures.map(\.name).joined(separator: ", ")
            throw ToolError("bench: \(failures.count) figure(s) regressed or are missing from the baseline (\(names))")
        }
        Output.out("bench: \(comparisons.count) figure(s) within their tolerance")
    }
}

/// Runs the benchmark suites in an optimized build and collects what they report.
enum BenchRun {
    private static let scratch = ".build-bench"
    /// The benchmark suites are named `...Benchmarks`; the slash ends the suite name in the test identifier.
    private static let filter = "Benchmarks/"

    /// `swift test` in release, with `@testable` imports enabled, over the benchmark suites only and one at a time: they
    /// time themselves, so nothing else may run. The suites append to the file named by `VMR_BENCH_OUTPUT`.
    static func measure(_ context: StepContext) async throws -> [BenchResult] {
        let directory = context.root.appending(path: scratch)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let results = directory.appending(path: "bench-results.jsonl")
        try? FileManager.default.removeItem(at: results)
        try await context.run(
            "env",
            [
                "VMR_BENCH_OUTPUT=\(results.path)", "swift", "test", "-c", "release", "-Xswiftc", "-enable-testing",
                "--scratch-path", scratch, "--no-parallel", "--filter", filter,
            ])
        guard FileManager.default.fileExists(atPath: results.path) else {
            throw ToolError("the benchmark run reported nothing: no suite named *Benchmarks wrote to \(results.path)")
        }
        let reported = try BenchResult.parse(String(contentsOf: results, encoding: .utf8))
        guard !reported.isEmpty else { throw ToolError("the benchmark run reported nothing") }
        return reported
    }
}
