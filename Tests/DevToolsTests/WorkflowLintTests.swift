import Foundation
import Testing

@testable import DevTools

/// `vmr check workflows` end to end against a local fixture release whose actionlint and zizmor are fakes.
struct WorkflowLintTests {
    private static let workflow = [".github/workflows/ci.yml": "on: push\n"]

    private func check(
        _ fixture: AnalyzerFixture, files: [String: String] = Self.workflow, environment: [String: String] = [:]
    ) async throws -> Invocation {
        try write(["Package.swift": "// swift-tools-version: 6.0\n"].merging(files) { _, new in new }, to: fixture.root)
        return try await fixture.vmr(
            ["check", "workflows"], environment: ["ACTIONLINT_BIN": "", "ZIZMOR_BIN": ""].merging(environment) { _, new in new })
    }

    @Test
    func theStepInstallsBothPinsAndRunsThemOverTheWorkflows() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let run = try await check(fixture)
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output.contains("installing actionlint 1.2.3 from file://"), "\(run.output)")
            #expect(run.output.contains("installing zizmor 1.2.3 from file://"), "\(run.output)")
            #expect(run.outputLines.contains { $0.hasPrefix("PASS  workflows (") })
            #expect(
                fixture.loggedCalls(of: "actionlint") == ["actionlint --version", "actionlint -no-color -oneline -shellcheck= -pyflakes="])
            #expect(
                fixture.loggedCalls(of: "zizmor")
                    == ["zizmor --version", "zizmor --offline --strict-collection --no-progress --format plain .github"])
        }
    }

    /// zizmor exits 1 under `--strict-collection` for a file it cannot parse and 11 to 14 for findings; actionlint exits 1.
    @Test(arguments: [("ACTIONLINT", "1"), ("ZIZMOR", "1"), ("ZIZMOR", "13")])
    func aFindingOrAnUnparsableFileFailsTheStep(tool: String, status: String) async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let run = try await check(fixture, environment: ["FAKE_EXIT_\(tool)": status])
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.outputLines.contains { $0.hasPrefix("FAIL  workflows (") })
        }
    }

    @Test
    func aTamperedArchiveIsRefusedAndNothingRuns() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base, tampered: ["zizmor"])
            let run = try await check(fixture)
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.combined.contains("zizmor 1.2.3: SHA-256 mismatch"), "\(run.combined)")
            #expect(fixture.loggedCalls(of: "zizmor").isEmpty, "the tampered binary never runs")
            #expect(fixture.loggedCalls(of: "actionlint") == ["actionlint --version"], "nothing is linted before both resolve")
        }
    }

    @Test
    func aCheckoutWithoutAGithubDirectoryFails() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let run = try await check(fixture, files: [:])
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.combined.contains("workflows: no .github directory to check"), "\(run.combined)")
        }
    }
}
