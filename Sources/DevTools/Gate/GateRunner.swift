import Foundation

/// A named step of the quality gate. A step passes when its closure returns and fails when it throws.
struct GateStep: Sendable {
    let name: String
    let run: @Sendable (StepContext) async throws -> Void
}

/// The outcome of one step.
struct StepResult: Equatable, Sendable {
    let name: String
    let passed: Bool
    let seconds: Int

    var line: String { "\(passed ? "PASS" : "FAIL")  \(name) (\(seconds)s)" }
}

/// Runs every selected step, even after a failure, and reports a PASS or FAIL line for each.
enum GateRunner {
    /// Returns whether every step passed.
    static func run(steps: [GateStep], context: StepContext) async -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        var results: [StepResult] = []
        for step in steps {
            results.append(await execute(step, context: context, clock: clock))
        }

        let total = Self.seconds(since: started, clock: clock)
        let failures = results.filter { !$0.passed }.count
        Output.out()
        Output.out("==== summary (\(total)s) ====")
        for result in results {
            Output.out(result.line)
        }
        appendToStepSummary(results.map(\.line), environment: context.environment)
        if failures > 0 {
            Output.out("FAILED: \(failures) of \(steps.count) step(s)")
        } else {
            Output.out("OK: all \(steps.count) step(s) passed")
        }
        return failures == 0
    }

    private static func execute(_ step: GateStep, context: StepContext, clock: ContinuousClock) async -> StepResult {
        Output.out()
        Output.out("==> \(step.name)")
        let started = clock.now
        var passed = true
        do {
            try await step.run(context)
        } catch {
            passed = false
            Output.err("error: \(error)")
        }
        let result = StepResult(name: step.name, passed: passed, seconds: seconds(since: started, clock: clock))
        Output.out(result.line)
        return result
    }

    private static func seconds(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Int {
        Int(start.duration(to: clock.now).components.seconds)
    }

    /// Mirrors the summary into the GitHub Actions job summary when running there.
    private static func appendToStepSummary(_ lines: [String], environment: [String: String]) {
        guard let path = environment["GITHUB_STEP_SUMMARY"], !path.isEmpty else { return }
        let text = (["### Quality gate", "```"] + lines + ["```"]).joined(separator: "\n") + "\n"
        guard let handle = FileHandle(forWritingAtPath: path) else {
            try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
