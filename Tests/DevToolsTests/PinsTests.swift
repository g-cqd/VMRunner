import Foundation
import Testing

@testable import DevTools

/// `vmr analyzers pins`: the CI workflows must pin the releases that analyzers.lock pins.
struct PinsTests {
    private func pins(workflows: [String: String]) async throws -> Invocation {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            try FileManager.default.removeItem(at: fixture.root.appending(path: ".github"))
            try write(workflows.reduce(into: [:]) { $0[".github/workflows/\($1.key)"] = $1.value }, to: fixture.root)
            return try await fixture.vmr(["analyzers", "pins"])
        }
    }

    @Test
    func agreeingWorkflowsPass() async throws {
        let run = try await pins(workflows: ["ci.yml": AnalyzerFixture.workflowText()])
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.output.contains("PASS  pins (workflow and analyzers.lock agree)"))
    }

    @Test
    func aWorkflowPinnedToAnotherCommitFails() async throws {
        let stale = AnalyzerFixture.workflowText(commit: {
            $0 == .dolly ? String(repeating: "f", count: 40) : AnalyzerFixture.commit(of: $0)
        })
        let run = try await pins(workflows: ["ci.yml": stale])
        #expect(run.status == 1)
        #expect(
            run.error.contains("pins: .github/workflows/ci.yml does not pin g-cqd/dolly@\(AnalyzerFixture.commit(of: .dolly)) # v1.2.3"),
            "\(run.error)")
        #expect(run.output.contains("FAIL  pins"))
        #expect(!run.error.contains("g-cqd/arcleak"), "only the disagreeing tool is reported")
    }

    @Test
    func aWorkflowWithAnotherVersionInputFails() async throws {
        let run = try await pins(workflows: ["ci.yml": AnalyzerFixture.workflowText(version: { $0 == .deadwood ? "1.2.4" : "1.2.3" })])
        #expect(run.status == 1)
        #expect(run.error.contains("does not set version: '1.2.3' # deadwood"), "\(run.error)")
        #expect(run.error.contains("does not pin g-cqd/deadwood@"), "the uses line carries the version too")
    }

    @Test
    func aStalePinInAnotherWorkflowFileFailsEvenWhenCiIsRight() async throws {
        let stale = AnalyzerFixture.workflowText(version: { _ in "0.0.1" })
        let run = try await pins(workflows: ["ci.yml": AnalyzerFixture.workflowText(), "nightly.yml": stale])
        #expect(run.status == 1)
        #expect(run.error.contains(".github/workflows/nightly.yml does not pin g-cqd/arcleak@"), "\(run.error)")
    }

    @Test
    func noWorkflowsAtAllIsAFailureForEveryTool() async throws {
        let run = try await pins(workflows: [:])
        #expect(run.status == 1)
        #expect(run.error.contains("pins: .github/workflows does not pin g-cqd/arcleak@"))
        #expect(run.error.contains("pins: .github/workflows does not set version: '1.2.3' # deadwood"))
    }
}
