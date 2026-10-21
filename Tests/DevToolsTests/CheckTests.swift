import Foundation
import Testing

/// `vmr check` end to end: the real binary, a fixture package, real swift-format, SwiftLint, swift build and swift test.
struct CheckTests {
    /// Runs `vmr check <steps>` on a fixture made of `files`.
    private func check(_ steps: [String], files: [String: String], environment: [String: String] = [:]) async throws -> Invocation {
        try await withTemporaryDirectory { directory in
            try write(files, to: directory)
            return try await VMR.vmr(["check"] + steps, in: directory, environment: environment)
        }
    }

    @Test(.timeLimit(.minutes(8)))
    func aPassingPackagePassesEveryStep() async throws {
        let summary = FileManager.default.temporaryDirectory.appending(path: "vmr-summary-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: summary) }
        let run = try await check(
            ["format", "swiftlint", "build", "test"], files: GateFixture.passing, environment: ["GITHUB_STEP_SUMMARY": summary.path])
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.combined.contains("Test run with 1 test"), "streaming the test step keeps its output visible")
        let text = try String(contentsOf: summary, encoding: .utf8)
        #expect(text.contains("| build | PASS | "), "\(text)")
        #expect(text.contains("- Tests: 1 (test)\n"), "the test count is read from the test step's output: \(text)")
        for step in ["format", "swiftlint", "build", "test"] {
            #expect(run.output.contains("==> \(step)\n"))
            #expect(run.outputLines.contains { $0.hasPrefix("PASS  \(step) (") && $0.hasSuffix("s)") })
        }
        #expect(run.output.contains("==== summary ("))
        #expect(run.outputLines.contains("OK: all 4 step(s) passed"))
    }

    @Test(.timeLimit(.minutes(8)))
    func aFormatViolationFailsTheFormatStepAndTheOthersStillRun() async throws {
        let run = try await check(
            ["format", "swiftlint", "build"],
            files: GateFixture.variant(["Sources/Fixture/Logic.swift": GateFixture.badlyFormatted])
        )
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.outputLines.contains { $0.hasPrefix("FAIL  format (") })
        #expect(run.outputLines.contains { $0.hasPrefix("PASS  swiftlint (") })
        #expect(run.outputLines.contains { $0.hasPrefix("PASS  build (") })
        #expect(run.outputLines.contains("FAILED: 1 of 3 step(s)"))
        #expect(run.error.contains("Logic.swift"), "swift-format names the offending file")
    }

    @Test(.timeLimit(.minutes(8)))
    func aSwiftLintViolationFailsTheSwiftLintStep() async throws {
        let run = try await check(
            ["swiftlint", "format", "build"],
            files: GateFixture.variant(["Sources/Fixture/Logic.swift": GateFixture.forceUnwrap])
        )
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.outputLines.contains { $0.hasPrefix("FAIL  swiftlint (") })
        #expect(run.outputLines.contains { $0.hasPrefix("PASS  format (") })
        #expect(run.outputLines.contains { $0.hasPrefix("PASS  build (") })
        #expect(run.output.contains("force_unwrapping"))
    }

    @Test(.timeLimit(.minutes(8)))
    func aBuildErrorFailsBuildAndTestButNotFormat() async throws {
        let run = try await check(
            ["build", "format", "test"],
            files: GateFixture.variant(["Sources/Fixture/Logic.swift": GateFixture.doesNotCompile])
        )
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.outputLines.contains { $0.hasPrefix("FAIL  build (") })
        #expect(run.outputLines.contains { $0.hasPrefix("PASS  format (") })
        #expect(run.outputLines.contains { $0.hasPrefix("FAIL  test (") })
        #expect(run.outputLines.contains("FAILED: 2 of 3 step(s)"))
        let summary = run.outputLines.drop { !$0.hasPrefix("==== summary") }.dropFirst().prefix(3).map { $0.prefix(4) }
        #expect(summary == ["FAIL", "PASS", "FAIL"], "the summary keeps the order the steps were given in")
    }

    @Test(.timeLimit(.minutes(8)))
    func aFailingTestFailsTheTestStepOnly() async throws {
        let run = try await check(
            ["build", "test"],
            files: GateFixture.variant(["Tests/FixtureTests/LogicTests.swift": GateFixture.failingTest])
        )
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.outputLines.contains { $0.hasPrefix("PASS  build (") })
        #expect(run.outputLines.contains { $0.hasPrefix("FAIL  test (") })
        #expect(run.outputLines.contains("FAILED: 1 of 2 step(s)"))
    }

    @Test
    func listPrintsEveryStepInOrderAndRunsNothing() async throws {
        let run = try await check(["--list"], files: GateFixture.passing)
        #expect(run.status == 0)
        #expect(
            run.outputLines.dropLast() == [
                "format", "swiftlint", "docs", "policy", "build", "test", "analyzers", "asan", "tsan", "ubsan", "release", "coverage",
                "bench",
                "publication",
            ])
        #expect(!run.output.contains("==>"))
    }

    @Test(arguments: [
        (["nope"], "unknown step 'nope'"),
        (["--bogus"], "unknown option '--bogus'"),
        (["--full", "format"], "mutually exclusive"),
    ])
    func badArgumentsExitWithUsageStatus(arguments: [String], message: String) async throws {
        let run = try await check(arguments, files: GateFixture.passing)
        #expect(run.status == 64)
        #expect(run.error.lowercased().contains(message), "\(run.error)")
    }

    @Test
    func theSwiftlintStepFailsClearlyWhenTheToolIsMissing() async throws {
        // An override that is not an executable: the step must fail with a clear message, not crash or fall back to PATH.
        let run = try await check(["swiftlint"], files: GateFixture.passing, environment: ["SWIFTLINT_BIN": "/nonexistent/swiftlint"])
        #expect(run.status == 1)
        #expect(run.error.contains("/nonexistent/swiftlint is not an executable"), "\(run.error)")
        #expect(run.outputLines.contains { $0.hasPrefix("FAIL  swiftlint (") })
    }
}
