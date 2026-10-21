import Foundation

/// The commands behind each gate step. A step fails by throwing; the first failing command ends it.
enum GateSteps {
    @Sendable
    static func format(_ context: StepContext) async throws {
        let paths = context.config.resolvedLintPaths(root: context.root)
        guard !paths.isEmpty else {
            throw ToolError("nothing to lint: none of Sources, Plugins, Tests exists (set lintPaths in .vmr.json)")
        }
        let tool = try await ToolLocator.swiftFormat(environment: context.environment)
        try await context.run(tool, ["lint", "--strict", "-r"] + paths)
    }

    @Sendable
    static func swiftlint(_ context: StepContext) async throws {
        try await context.run("swiftlint", ["lint", "--quiet"])
    }

    @Sendable
    static func build(_ context: StepContext) async throws {
        try await context.run("swift", ["build"])
    }

    /// `SWIFT_TEST_FLAGS` adds flags to the plain test run (CI uses it for `--xunit-output`).
    @Sendable
    static func test(_ context: StepContext) async throws {
        let extra = (context.environment["SWIFT_TEST_FLAGS"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        try await context.run("swift", ["test"] + extra)
    }

    @Sendable
    static func analyzers(_ context: StepContext) async throws {
        var service = AnalyzerService(root: context.root, environment: context.environment)
        service.facts = context.facts
        guard try await service.run(tools: AnalyzerTool.allCases) else { throw ToolError("the analyzers reported failures") }
    }

    /// The documentation law of `docs/WHITE-PAPER.md` over `docs/` and `README.md`.
    @Sendable
    static func docs(_ context: StepContext) async throws {
        let report = DocsChecker.check(root: context.root)
        for violation in report.violations {
            Output.err(violation.description)
        }
        guard report.violations.isEmpty else {
            throw ToolError("docs: \(report.violations.count) violation(s) in \(report.filesChecked) file(s) checked")
        }
        Output.out("docs: \(report.filesChecked) file(s) checked, no violations")
    }

    /// SwiftPM compiles C targets (swift-subprocess has one) with `-fsanitize=undefined`, but the Swift link step does not
    /// add the UBSan runtime, so the executables fail to link with undefined `___ubsan_handle_*` symbols. Asking the
    /// clang linker driver for the sanitizer links the runtime.
    static let ubsanLinkerArguments = ["-Xswiftc", "-Xclang-linker", "-Xswiftc", "-fsanitize=undefined"]

    static func sanitizer(
        _ name: String,
        scratch: String,
        linkerArguments: [String] = []
    ) -> @Sendable (StepContext) async throws -> Void {
        { context in
            let arguments = ["test", "--sanitize=\(name)", "--scratch-path", scratch] + skipArguments(context) + linkerArguments
            try await context.run("swift", arguments)
        }
    }

    @Sendable
    static func release(_ context: StepContext) async throws {
        try await context.run("swift", ["build", "-c", "release", "--scratch-path", ".build-release"])
    }

    /// `--skip` arguments for the runs that must not include the tooling's own end-to-end suites.
    static func skipArguments(_ context: StepContext) -> [String] {
        (context.config.skipTestsWhenInstrumented ?? []).flatMap { ["--skip", $0] }
    }
}
