import Foundation

/// The GitHub Actions job summary of a gate run: a Markdown table of the steps, then the figures the steps reported.
enum GateSummary {
    static let environmentVariable = "GITHUB_STEP_SUMMARY"

    /// The file the summary is appended to, when the environment names one.
    static func path(in environment: [String: String]) -> String? {
        environment[environmentVariable].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func markdown(results: [StepResult], totalSeconds: Int, facts: GateFacts.Snapshot?) -> String {
        var lines = ["### Quality gate", "", "| Step | Result | Duration |", "|---|---|---|"]
        lines += results.map { "| \($0.name) | \($0.passed ? "PASS" : "FAIL") | \($0.seconds)s |" }
        let failures = results.filter { !$0.passed }.count
        let verdict = failures == 0 ? "All \(results.count) step(s) passed" : "\(failures) of \(results.count) step(s) failed"
        lines += ["", "\(verdict) in \(totalSeconds)s."]

        if let facts {
            var details: [String] = []
            let tests = results.compactMap { result in facts.tests[result.name].map { "\($0) (\(result.name))" } }
            if !tests.isEmpty { details.append("- Tests: \(tests.joined(separator: ", "))") }
            if let coverage = facts.coverage {
                details.append("- \(Coverage.line(percent: coverage.percent, minimum: coverage.minimum))")
            }
            let findings = AnalyzerTool.allCases.compactMap { tool in facts.findings[tool].map { "\(tool.rawValue) \($0)" } }
            if !findings.isEmpty { details.append("- Analyzer findings (errors and warnings): \(findings.joined(separator: ", "))") }
            if !details.isEmpty { lines += [""] + details }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Appends the summary to the file; a summary that cannot be written is reported but never fails the gate.
    static func append(_ text: String, to path: String) {
        do {
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: Data(text.utf8))
            } else {
                try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            }
        } catch {
            Output.err("warning: cannot write the job summary to \(path): \(error)")
        }
    }
}
