import Foundation

/// Per-repository settings of the quality gate, read from an optional `.vmr.json` at the package root. Every key
/// is optional; a repository without the file gets the defaults below.
///
/// ```json
/// {
///   "lintPaths": ["Sources", "Plugins", "Tests"],
///   "skipTestsWhenInstrumented": ["DevToolsTests"],
///   "coverage": { "minimum": 55, "testBundles": ["VMRunnerTests"], "ignoreRegex": "Tests/|\\.build|/Views/" }
/// }
/// ```
struct ProjectConfig: Decodable, Equatable {
    static let fileName = ".vmr.json"
    static let defaultCoverageMinimum = 55.0
    static let defaultLintDirectories = ["Sources", "Plugins", "Tests"]

    struct Coverage: Decodable, Equatable {
        /// Line coverage, in percent, below which the gate fails.
        var minimum: Double?
        /// Test bundles (without `.xctest`) whose coverage is measured. Default: every bundle the run produced.
        var testBundles: [String]?
        /// `llvm-cov -ignore-filename-regex`: files that cannot run in a unit test (UI, entitlement-gated code).
        var ignoreRegex: String?
    }

    /// Directories handed to swift-format. Default: those of `Sources`, `Plugins`, `Tests` that exist.
    var lintPaths: [String]?
    /// Test targets left out of the sanitizer and coverage runs (`swift test --skip`): suites that drive nested
    /// builds gain nothing from instrumentation and would distort the coverage figure.
    var skipTestsWhenInstrumented: [String]?
    var coverage: Coverage?

    static func load(root: URL) throws -> Self {
        let url = root.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch {
            throw ToolError("\(fileName) is not valid: \(error)")
        }
    }

    /// The directories to lint: the configured ones, or the conventional ones that exist under `root`.
    func resolvedLintPaths(root: URL) -> [String] {
        if let lintPaths { return lintPaths }
        return Self.defaultLintDirectories.filter { directory in
            (try? root.appending(path: directory).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    /// `COVERAGE_MIN` from the environment wins over the file, which wins over the default.
    func resolvedCoverageMinimum(environment: [String: String]) throws -> Double {
        if let raw = environment["COVERAGE_MIN"], !raw.isEmpty {
            guard let value = Double(raw) else { throw ToolError("COVERAGE_MIN='\(raw)' is not a number") }
            return value
        }
        return coverage?.minimum ?? Self.defaultCoverageMinimum
    }
}
