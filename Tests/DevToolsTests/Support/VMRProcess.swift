import Foundation
import Testing

@testable import DevTools

/// The outcome of a `vmr` (or git) invocation made by an end-to-end test.
struct Invocation {
    let status: Int32
    let output: String
    let error: String

    /// Standard output and standard error together, for assertions that do not care which stream a message used.
    var combined: String { output + error }

    var outputLines: [String] { output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
}

/// Locates the products of this package's build and runs the REAL `vmr` binary against fixtures.
enum VMR {
    /// The directory holding `vmr` and `FakeAnalyzer`: the one that holds the running test bundle.
    static func productsDirectory() -> URL {
        Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
    }

    static func binary(named name: String) throws -> URL {
        let url = productsDirectory().appending(path: name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw TestSetupError("\(url.path) was not built") }
        return url
    }

    /// The environment end-to-end runs get: the tools and caches a build needs, nothing inherited from this test
    /// process (no XCTest or SwiftPM variables that would confuse a nested `swift test`), and a git setup that
    /// cannot read the user's configuration.
    static func cleanEnvironment(adding extra: [String: String] = [:]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let keep = ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS"]
        var environment = inherited.filter { keep.contains($0.key) }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment.merging(extra) { _, new in new }
    }

    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        in directory: URL,
        environment: [String: String] = [:],
        timeout: Duration = .seconds(420)
    ) async throws -> Invocation {
        let swiftlint = try await PinnedSwiftLint.path()
        let spec = CommandSpec(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: cleanEnvironment(adding: ["SWIFTLINT_BIN": swiftlint].merging(environment) { _, new in new }),
            inheritEnvironment: false,
            timeout: timeout
        )
        let result = try await ProcessRunner.run(spec)
        #expect(!result.timedOut, "\(executable) \(arguments.joined(separator: " ")) timed out")
        return Invocation(status: result.status, output: result.standardOutput, error: result.standardError)
    }

    /// Runs `vmr <arguments>` in `directory`.
    @discardableResult
    static func vmr(_ arguments: [String], in directory: URL, environment: [String: String] = [:]) async throws -> Invocation {
        try await run(try binary(named: "vmr").path, arguments, in: directory, environment: environment)
    }
}

/// The SwiftLint the fixture packages and repositories lint with. They carry no lock of their own, so every end-to-end
/// run gets it as `SWIFTLINT_BIN`: the one in this process's environment, otherwise the release this checkout pins
/// (downloaded and verified on first use, once per test process).
enum PinnedSwiftLint {
    private static let resolution = Task {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try await ToolLocator.swiftlint(root: checkout, environment: ProcessInfo.processInfo.environment)
    }

    static func path() async throws -> String {
        try await resolution.value
    }
}

struct TestSetupError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// A unique temporary directory, removed when the closure returns. Every test works in its own, so tests run in parallel.
func withTemporaryDirectory<Value>(_ body: (URL) async throws -> Value) async throws -> Value {
    let url = FileManager.default.temporaryDirectory.appending(path: "vmr-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url.resolvingSymlinksInPath())
}

/// Writes `files` (relative path to contents) below `directory`.
func write(_ files: [String: String], to directory: URL) throws {
    for (path, contents) in files {
        let url = directory.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}

/// Anchors `Bundle(for:)` to the test bundle, which sits next to the other products of the package.
private final class BundleToken {}
