import Foundation
import Testing

@testable import DevTools

/// The benchmark gate end to end: a fixture package whose benchmark suite reports the figures it is told to, run through
/// the real `vmr` against a committed baseline. One fixture, one release build, then a run per case.
struct BenchGateTests {
    /// A suite named like the real benchmarks that appends three figures (and a fourth on request) to the results file.
    private static let benchmarks = """
        import Foundation
        import Testing

        @Suite struct FixtureBenchmarks {
          @Test func reports() throws {
            let environment = ProcessInfo.processInfo.environment
            guard let path = environment["VMR_BENCH_OUTPUT"] else { return }
            func line(
              _ name: String, _ unit: String, _ direction: String, _ tolerance: String, _ enforced: Bool, _ value: String
            ) -> String {
              "{\\"name\\":\\"\\(name)\\",\\"unit\\":\\"\\(unit)\\",\\"direction\\":\\"\\(direction)\\",\\"tolerance\\":\\(tolerance),"
                + "\\"enforced\\":\\(enforced),\\"value\\":\\(value)}\\n"
            }
            var text = line("fixture.allocations", "allocations", "lower", "0", true, environment["FIXTURE_ALLOCATIONS"] ?? "4")
            text += line("fixture.instructions", "instructions", "lower", "0.05", true, environment["FIXTURE_INSTRUCTIONS"] ?? "1000")
            text += line("fixture.rate", "MiB/s", "higher", "0.3", false, environment["FIXTURE_RATE"] ?? "1000")
            if environment["FIXTURE_EXTRA"] != nil { text += line("fixture.extra", "allocations", "lower", "0", true, "1") }
            try text.write(toFile: path, atomically: true, encoding: .utf8)
          }
        }

        """

    private static let baseline = """
        {
          "benchmarks": {
            "fixture.allocations": { "direction": "lower", "enforced": true, "tolerance": 0, "unit": "allocations", "value": 4 },
            "fixture.instructions": { "direction": "lower", "enforced": true, "tolerance": 0.05, "unit": "instructions", "value": 1000 },
            "fixture.rate": { "direction": "higher", "enforced": false, "tolerance": 0.3, "unit": "MiB/s", "value": 1000 }
          }
        }
        """

    /// Whether the run printed a line that starts with `label` and then names the figure and its numbers.
    private func hasLine(_ run: Invocation, _ label: String, _ rest: String) -> Bool {
        run.outputLines.contains { $0.hasPrefix(label + " ") && $0.hasSuffix(" " + rest) }
    }

    private func bench(_ directory: URL, _ environment: [String: String] = [:]) async throws -> Invocation {
        try await VMR.vmr(["check", "bench"], in: directory, environment: environment)
    }

    @Test(.timeLimit(.minutes(10)))
    func theGateRatchetsTheFiguresAgainstTheCommittedBaseline() async throws {
        try await withTemporaryDirectory { directory in
            try write(
                GateFixture.variant(["Tests/FixtureTests/FixtureBenchmarks.swift": Self.benchmarks, ".vmr-bench.json": Self.baseline]),
                to: directory)

            let equal = try await bench(directory)
            #expect(equal.status == 0, "\(equal.combined)")
            #expect(hasLine(equal, "ok", "fixture.allocations: 4 allocations (baseline 4)"), "\(equal.output)")
            #expect(equal.output.contains("bench: 3 figure(s) within their tolerance"))
            #expect(!equal.output.contains("lock them in"), "nothing improved")

            let regressed = try await bench(directory, ["FIXTURE_ALLOCATIONS": "5"])
            #expect(regressed.status == 1, "\(regressed.combined)")
            #expect(hasLine(regressed, "REGRESSED", "fixture.allocations: 5 allocations (baseline 4, +25.0%)"), "\(regressed.output)")
            #expect(regressed.outputLines.contains { $0.hasPrefix("FAIL  bench (") })
            #expect(
                regressed.error.contains("1 figure(s) regressed or are missing from the baseline (fixture.allocations)"),
                "\(regressed.error)")

            let withinTolerance = try await bench(directory, ["FIXTURE_INSTRUCTIONS": "1050"])
            #expect(withinTolerance.status == 0, "a figure exactly at its tolerance passes: \(withinTolerance.combined)")
            let beyondTolerance = try await bench(directory, ["FIXTURE_INSTRUCTIONS": "1051"])
            #expect(beyondTolerance.status == 1, "\(beyondTolerance.combined)")
            #expect(
                hasLine(beyondTolerance, "REGRESSED", "fixture.instructions: 1051 instructions (baseline 1000, +5.1%)"),
                "\(beyondTolerance.output)")

            let improved = try await bench(directory, ["FIXTURE_ALLOCATIONS": "3"])
            #expect(improved.status == 0, "an improvement does not fail: \(improved.combined)")
            #expect(hasLine(improved, "improved", "fixture.allocations: 3 allocations (baseline 4, -25.0%)"), "\(improved.output)")
            #expect(
                improved.output.contains(
                    "bench: 1 figure(s) improved beyond their tolerance; lock them in with `swift run vmr bench record`"))

            let reportedOnly = try await bench(directory, ["FIXTURE_RATE": "100"])
            #expect(reportedOnly.status == 0, "a figure that is not enforced never fails: \(reportedOnly.combined)")
            #expect(
                hasLine(reportedOnly, "slower (reported only)", "fixture.rate: 100 MiB/s (baseline 1000, -90.0%)"), "\(reportedOnly.output)"
            )

            let unrecorded = try await bench(directory, ["FIXTURE_EXTRA": "1"])
            #expect(unrecorded.status == 1, "a figure the baseline does not know fails until it is recorded: \(unrecorded.combined)")
            #expect(hasLine(unrecorded, "UNRECORDED", "fixture.extra: 1 allocations (not in the baseline)"), "\(unrecorded.output)")
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func recordingWritesTheFiguresAndKeepsTheToleranceOfAnExistingEntry() async throws {
        try await withTemporaryDirectory { directory in
            // The fixture's baseline starts without the instructions figure, whose entry is therefore new, and with a
            // looser tolerance on the allocations than the benchmark suggests, which a record must keep.
            let partial = """
                {
                  "benchmarks": {
                    "fixture.allocations": { "direction": "lower", "enforced": true, "tolerance": 0.5, "unit": "allocations", "value": 9 },
                    "fixture.gone": { "direction": "lower", "enforced": true, "tolerance": 0, "unit": "allocations", "value": 1 }
                  }
                }
                """
            try write(
                GateFixture.variant(["Tests/FixtureTests/FixtureBenchmarks.swift": Self.benchmarks, ".vmr-bench.json": partial]),
                to: directory)

            let record = try await VMR.vmr(["bench", "record"], in: directory, environment: ["FIXTURE_ALLOCATIONS": "3"])
            #expect(record.status == 0, "\(record.combined)")
            #expect(record.output.contains("recorded 3 figure(s) in .vmr-bench.json"), "\(record.output)")

            let recorded = try JSONDecoder().decode(
                BenchBaseline.self, from: Data(contentsOf: directory.appending(path: ".vmr-bench.json")))
            #expect(
                Set(recorded.benchmarks.keys) == ["fixture.allocations", "fixture.instructions", "fixture.rate"],
                "a vanished figure is dropped")
            #expect(recorded.benchmarks["fixture.allocations"]?.value == 3)
            #expect(recorded.benchmarks["fixture.allocations"]?.tolerance == 0.5, "the tolerance of an existing entry is kept")
            #expect(recorded.benchmarks["fixture.instructions"]?.tolerance == 0.05, "a new entry takes the benchmark's suggestion")
            #expect(recorded.benchmarks["fixture.rate"]?.enforced == false)

            let verified = try await bench(directory, ["FIXTURE_ALLOCATIONS": "3"])
            #expect(verified.status == 0, "the run that was recorded passes: \(verified.combined)")

            try FileManager.default.removeItem(at: directory.appending(path: ".vmr-bench.json"))
            let missing = try await bench(directory)
            #expect(missing.status == 1)
            #expect(missing.error.contains("no benchmark baseline at "), "\(missing.error)")
            #expect(missing.error.contains("swift run vmr bench record"))
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func aRunThatReportsNothingFails() async throws {
        try await withTemporaryDirectory { directory in
            try write(GateFixture.variant([".vmr-bench.json": Self.baseline]), to: directory)
            let run = try await bench(directory)
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("the benchmark run reported nothing"), "\(run.error)")
        }
    }

    @Test
    func aFigureMovesTheWrongWayOnlyBeyondItsToleranceAndInItsOwnDirection() {
        func entry(_ value: Double, _ direction: BenchDirection, tolerance: Double) -> BenchBaseline.Entry {
            BenchBaseline.Entry(value: value, unit: "u", direction: direction, tolerance: tolerance, enforced: true)
        }
        func result(_ value: Double, _ direction: BenchDirection) -> BenchResult {
            BenchResult(name: "f", unit: "u", direction: direction, value: value, tolerance: 0, enforced: true)
        }
        func verdict(_ measured: Double, _ direction: BenchDirection, baseline: Double, tolerance: Double) -> BenchComparison.Verdict {
            Bench.compare(
                [result(measured, direction)], against: BenchBaseline(benchmarks: ["f": entry(baseline, direction, tolerance: tolerance)]))[
                    0
                ]
                .verdict
        }
        #expect(verdict(5, .lower, baseline: 5, tolerance: 0) == .unchanged)
        #expect(verdict(6, .lower, baseline: 5, tolerance: 0) == .regressed)
        #expect(verdict(4, .lower, baseline: 5, tolerance: 0) == .improved)
        #expect(verdict(1, .lower, baseline: 0, tolerance: 0) == .regressed, "any allocation is a regression from none")
        #expect(verdict(70, .higher, baseline: 100, tolerance: 0.3) == .unchanged)
        #expect(verdict(69, .higher, baseline: 100, tolerance: 0.3) == .regressed)
        #expect(verdict(131, .higher, baseline: 100, tolerance: 0.3) == .improved)
    }
}
