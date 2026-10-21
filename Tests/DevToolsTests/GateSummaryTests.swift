import Foundation
import Testing

@testable import DevTools

/// The GitHub Actions job summary written by `vmr check` when GITHUB_STEP_SUMMARY names a file.
struct GateSummaryTests {
    private func summaryRun(
        _ files: [String: String],
        steps: [String] = ["docs"],
        existing: String? = nil,
        environment: [String: String] = [:]
    ) async throws -> (run: Invocation, summary: String?) {
        try await withTemporaryDirectory { directory in
            try write(files, to: directory.appending(path: "package"))
            let summary = directory.appending(path: "summary.md")
            if let existing { try Data(existing.utf8).write(to: summary) }
            let run = try await VMR.vmr(
                ["check"] + steps + ["--root", directory.appending(path: "package").path],
                in: directory,
                environment: environment.merging(["GITHUB_STEP_SUMMARY": summary.path]) { _, new in new }
            )
            return (run, try? String(contentsOf: summary, encoding: .utf8))
        }
    }

    @Test
    func aTableOfTheStepsIsAppendedToTheFile() async throws {
        let (run, summary) = try await summaryRun(DocsFixture.passing, existing: "# Earlier step\n")
        #expect(run.status == 0, "\(run.combined)")
        let text = try #require(summary)
        #expect(
            text.hasPrefix("# Earlier step\n### Quality gate\n\n| Step | Result | Duration |\n|---|---|---|\n| docs | PASS | "), "\(text)")
        #expect(text.contains("s |\n\nAll 1 step(s) passed in "), "\(text)")
        #expect(!text.contains("Tests:") && !text.contains("coverage") && !text.contains("Analyzer"), "only what the steps reported")
    }

    @Test
    func aFailedStepIsMarkedAndCounted() async throws {
        let (run, summary) = try await summaryRun(DocsFixture.variant(["docs/WHITE-PAPER.md": String(repeating: "x\n", count: 201)]))
        #expect(run.status == 1)
        let text = try #require(summary)
        #expect(text.contains("| docs | FAIL | "), "\(text)")
        #expect(text.contains("1 of 1 step(s) failed in "), "\(text)")
    }

    @Test
    func nothingIsWrittenOrPrintedWithoutTheVariable() async throws {
        try await withTemporaryDirectory { directory in
            try write(DocsFixture.passing, to: directory)
            let plain = try await VMR.vmr(["check", "docs", "--root", directory.path], in: directory)
            let empty = try await VMR.vmr(
                ["check", "docs", "--root", directory.path], in: directory, environment: ["GITHUB_STEP_SUMMARY": ""])
            for run in [plain, empty] {
                #expect(run.status == 0, "\(run.combined)")
                #expect(!run.combined.contains("Quality gate") && !run.combined.contains("summary.md") && !run.combined.contains("warning"))
                #expect(run.outputLines.contains("OK: all 1 step(s) passed"))
            }
        }
    }

    @Test
    func anUnwritableSummaryIsReportedButDoesNotFailTheGate() async throws {
        try await withTemporaryDirectory { directory in
            try write(DocsFixture.passing, to: directory)
            let run = try await VMR.vmr(
                ["check", "docs", "--root", directory.path], in: directory,
                environment: ["GITHUB_STEP_SUMMARY": directory.appending(path: "missing/summary.md").path])
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.error.contains("warning: cannot write the job summary to "), "\(run.error)")
        }
    }

    @Test
    func analyzerFindingsAreCountedPerToolAndNotesAreNot() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            try write(["Package.swift": "// swift-tools-version: 6.0\n"], to: fixture.root)
            let summary = base.appending(path: "summary.md")
            let run = try await fixture.vmr(
                ["check", "analyzers"],
                environment: [
                    "GITHUB_STEP_SUMMARY": summary.path, "FAKE_FINDINGS_DOLLY": "2", "FAKE_EXIT_DOLLY": "1", "FAKE_FINDINGS_DEADWOOD": "0",
                ])
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.output.contains("Sources/A.swift:2:1: warning: [fake] a finding"), "the analyzers' own output still streams")
            let text = try String(contentsOf: summary, encoding: .utf8)
            #expect(text.contains("| analyzers | FAIL | "), "\(text)")
            #expect(text.contains("- Analyzer findings (errors and warnings): arcleak 0, dolly 2, deadwood 0\n"), "\(text)")
        }
    }

    @Test
    func testCountsAreSummedPerStepFromTheTestRunLines() {
        let facts = GateFacts()
        for line in [
            "◇ Test run started.", "✔ Test run with 412 tests in 58 suites passed after 3.2 seconds.",
            "✘ Test run with 1 test in 1 suite failed after 0.01 seconds with 1 issue.", "Test run with lots of tests",
        ] {
            facts.observe(line, step: "test")
        }
        facts.observe("✔ Test run with 7 tests in 1 suite passed", step: "asan")
        #expect(facts.snapshot.tests == ["test": 413, "asan": 7])
    }

    @Test
    func onlyErrorsAndWarningsWithAPositionAreFindings() {
        #expect(GateFacts.isFinding("Sources/A.swift:12:3: warning: [x] message"))
        #expect(GateFacts.isFinding("Sources/A.swift:12:3: error: [x] message"))
        #expect(!GateFacts.isFinding("Sources/A.swift:12:3: note: [x] message"))
        #expect(!GateFacts.isFinding("arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 208 file(s)"))
    }

    @Test
    func theMarkdownListsTheFiguresInTheOrderOfTheSteps() {
        let results = [
            StepResult(name: "test", passed: true, seconds: 12), StepResult(name: "coverage", passed: false, seconds: 40),
            StepResult(name: "asan", passed: true, seconds: 90),
        ]
        var facts = GateFacts.Snapshot()
        facts.tests = ["asan": 5, "test": 7]
        facts.coverage = GateFacts.CoverageFigure(percent: 61.25, minimum: 55)
        facts.findings = [.dolly: 3, .arcleak: 0]
        #expect(
            GateSummary.markdown(results: results, totalSeconds: 142, facts: facts) == """
                ### Quality gate

                | Step | Result | Duration |
                |---|---|---|
                | test | PASS | 12s |
                | coverage | FAIL | 40s |
                | asan | PASS | 90s |

                1 of 3 step(s) failed in 142s.

                - Tests: 7 (test), 5 (asan)
                - logic-layer line coverage: 61.3% (minimum 55%)
                - Analyzer findings (errors and warnings): arcleak 0, dolly 3

                """)
    }
}
