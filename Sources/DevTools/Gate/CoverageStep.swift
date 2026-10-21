import Foundation

extension GateSteps {
    private static let scratch = ".build-cov"
    private static let defaultIgnoreRegex = #"Tests/|\.build"#

    /// Line coverage of the logic layer must stay at or above the minimum. The summary of
    /// `llvm-cov export -summary-only` is kept in `.build-cov/coverage-summary.json`.
    @Sendable
    static func coverage(_ context: StepContext) async throws {
        let minimum = try context.config.resolvedCoverageMinimum(environment: context.environment)
        try await context.run("swift", ["test", "--enable-code-coverage", "--scratch-path", scratch] + skipArguments(context))

        let binPath = try await context.capture("swift", ["build", "--show-bin-path", "--scratch-path", scratch])
        let products = URL(fileURLWithPath: binPath.split(whereSeparator: \.isNewline).last.map(String.init) ?? "")
        let profile = products.appending(path: "codecov/default.profdata")
        guard FileManager.default.fileExists(atPath: profile.path) else {
            throw ToolError("coverage profile not found at \(profile.path)")
        }
        let binaries = try testBinaries(in: products, bundles: context.config.coverage?.testBundles)

        var arguments = ["llvm-cov", "export", "-summary-only", binaries[0].path]
        for binary in binaries.dropFirst() {
            arguments += ["-object", binary.path]
        }
        arguments += [
            "-instr-profile=\(profile.path)",
            "-ignore-filename-regex=\(context.config.coverage?.ignoreRegex ?? defaultIgnoreRegex)",
        ]
        let summary = try await context.capture("xcrun", arguments)
        try Data(summary.utf8).write(to: context.root.appending(path: "\(scratch)/coverage-summary.json"))

        let percent = try Coverage.linePercent(fromExport: Data(summary.utf8))
        Output.out(Coverage.line(percent: percent, minimum: minimum))
        guard percent >= minimum else {
            throw ToolError("coverage fell below COVERAGE_MIN=\(Coverage.describe(minimum: minimum))")
        }
    }

    /// The executables inside the named `.xctest` bundles, or inside every bundle the run produced.
    private static func testBinaries(in products: URL, bundles: [String]?) throws -> [URL] {
        let names =
            try bundles
            ?? FileManager.default.contentsOfDirectory(atPath: products.path)
            .filter { $0.hasSuffix(".xctest") }
            .map { String($0.dropLast(".xctest".count)) }
            .sorted()
        let binaries = names.map { products.appending(path: "\($0).xctest/Contents/MacOS/\($0)") }
        if binaries.isEmpty { throw ToolError("no .xctest bundle found in \(products.path)") }
        if let missing = binaries.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            throw ToolError("test binary not found at \(missing.path)")
        }
        return binaries
    }
}
