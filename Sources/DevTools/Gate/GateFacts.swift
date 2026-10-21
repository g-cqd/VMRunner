import Foundation
import RegexBuilder
import Synchronization

/// The figures a gate run collects for the job summary: test counts per step, the coverage and the analyzer findings.
///
/// It exists only when a summary was asked for (`GITHUB_STEP_SUMMARY`), because collecting test counts means streaming
/// the output of the steps through this process instead of letting the children write to the descriptors directly.
final class GateFacts: Sendable {
    struct CoverageFigure: Equatable {
        let percent: Double
        let minimum: Double
    }

    struct Snapshot: Equatable {
        /// `Test run with N tests` lines, summed per step.
        var tests: [String: Int] = [:]
        var coverage: CoverageFigure?
        /// Error and warning diagnostics per analyzer; a tool that ran without any is present with 0.
        var findings: [AnalyzerTool: Int] = [:]
    }

    private let state = Mutex(Snapshot())

    var snapshot: Snapshot { state.withLock { $0 } }

    /// A facts collector when the environment asks for a job summary, otherwise nil.
    static func collecting(environment: [String: String]) -> GateFacts? {
        GateSummary.path(in: environment) == nil ? nil : GateFacts()
    }

    func observe(_ line: String, step: String) {
        guard let count = Self.testCount(in: line) else { return }
        state.withLock { $0.tests[step, default: 0] += count }
    }

    func recordCoverage(percent: Double, minimum: Double) {
        state.withLock { $0.coverage = CoverageFigure(percent: percent, minimum: minimum) }
    }

    func analyzerStarted(_ tool: AnalyzerTool) {
        state.withLock { if $0.findings[tool] == nil { $0.findings[tool] = 0 } }
    }

    func observeAnalyzer(_ tool: AnalyzerTool, line: String) {
        guard Self.isFinding(line) else { return }
        state.withLock { $0.findings[tool, default: 0] += 1 }
    }

    // MARK: Parsing

    /// N of the Swift Testing line `✔ Test run with N tests in M suites passed after ...`.
    static func testCount(in line: String) -> Int? {
        guard line.contains("Test run with") else { return nil }
        let testRun = Regex {
            "Test run with "
            TryCapture {
                OneOrMore(CharacterClass("0"..."9"))
            } transform: {
                Int($0)
            }
            " test"
        }
        return line.firstMatch(of: testRun)?.output.1
    }

    /// Whether the line is an analyzer diagnostic of severity error or warning (`path:line:column: warning: ...`);
    /// notes never fail an analyzer and are not counted.
    static func isFinding(_ line: String) -> Bool {
        guard line.contains(": warning: ") || line.contains(": error: ") else { return false }
        let diagnostic = Regex {
            ":"
            OneOrMore(CharacterClass("0"..."9"))
            ":"
            OneOrMore(CharacterClass("0"..."9"))
            ": "
            ChoiceOf {
                "error"
                "warning"
            }
            ": "
        }
        return line.contains(diagnostic)
    }
}
