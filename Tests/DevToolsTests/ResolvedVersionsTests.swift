import Foundation
import Testing

/// Every build the tooling and the workflows start takes its versions from the committed `Package.resolved` only.
struct ResolvedVersionsTests {
    private static let flag = "--only-use-versions-from-resolved-file"
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// A `swift` that only records its arguments, put first on `PATH`.
    private func withFakeSwift(
        exitStatus: Int = 0,
        _ body: (_ environment: [String: String], _ log: URL, _ directory: URL) async throws -> Void
    ) async throws {
        try await withTemporaryDirectory { directory in
            let bin = directory.appending(path: "bin", directoryHint: .isDirectory)
            let log = directory.appending(path: "swift.log")
            try write(["bin/swift": "#!/bin/sh\necho \"$@\" >> '\(log.path)'\nexit \(exitStatus)\n"], to: directory)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "swift").path)
            let path = bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            try await body(["PATH": path], log, directory)
        }
    }

    private func calls(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test
    func everySwiftBuildAndTestOfTheGateReadsOnlyTheResolvedFile() async throws {
        try await withFakeSwift { environment, log, directory in
            try write(GateFixture.passing, to: directory)
            _ = try await VMR.vmr(["check", "build", "test", "asan", "release", "coverage"], in: directory, environment: environment)
            let recorded = calls(log)
            #expect(recorded.count == 6, "build, test, asan, release, and coverage's test and bin-path: \(recorded)")
            for call in recorded {
                #expect(call.contains(Self.flag), "swift \(call)")
            }
        }
    }

    @Test
    func theThreadSanitizerStepSuppressesOnlyTheContinuationFramesOfTheUninstrumentedRuntime() async throws {
        try await withTemporaryDirectory { directory in
            let bin = directory.appending(path: "bin", directoryHint: .isDirectory)
            let log = directory.appending(path: "env.log")
            try write(
                ["bin/swift": "#!/bin/sh\necho \"$TSAN_OPTIONS|$@\" >> '\(log.path)'\nexit 0\n"], to: directory)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "swift").path)
            try write(GateFixture.passing, to: directory)
            let path = bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            _ = try await VMR.vmr(["check", "asan", "tsan"], in: directory, environment: ["PATH": path])
            let lines = calls(log)
            let thread = try #require(lines.first { $0.contains("--sanitize=thread") })
            let address = try #require(lines.first { $0.contains("--sanitize=address") })
            #expect(thread.hasPrefix("suppressions=\(directory.path)/Scripts/tsan.supp|"), "\(thread)")
            #expect(address.hasPrefix("|"), "only the thread sanitizer gets options: \(address)")
        }
        let file = try String(contentsOf: Self.root.appending(path: "Scripts/tsan.supp"), encoding: .utf8)
        let patterns = file.split(separator: "\n").filter { $0.hasPrefix("race:") }
        #expect(patterns == ["race:withUnsafeThrowingContinuation", "race:withUnsafeContinuation"], "\(patterns)")
    }

    @Test
    func theAppBuildReadsOnlyTheResolvedFile() async throws {
        try await withFakeSwift(exitStatus: 1) { environment, log, directory in
            try write(AppFixture.files(), to: directory)
            let runner = try AppFixture.runner(in: directory)
            let run = try await VMR.vmr(["build-app", "--container-runner", runner.path], in: directory, environment: environment)
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("swift build failed"), "\(run.error)")
            #expect(calls(log).count == 1 && calls(log).allSatisfy { $0.contains(Self.flag) }, "\(calls(log))")
        }
    }

    @Test
    func theAppBuildBuildsTheRunnerFromItsOwnPackageInTheSameConfigurationReadingOnlyTheResolvedFile() async throws {
        try await withFakeSwift(exitStatus: 1) { environment, log, directory in
            try write(AppFixture.files(), to: directory)
            let run = try await VMR.vmr(["build-app", "debug"], in: directory, environment: environment)
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("swift build failed"), "\(run.error)")
            let recorded = calls(log)
            #expect(recorded.count == 1, "the runner's package is built first, and its failure ends the run: \(recorded)")
            let call = try #require(recorded.first)
            #expect(call.contains(Self.flag), "\(call)")
            #expect(call.contains("--package-path \(directory.path)/Packages/Containers"), "\(call)")
            #expect(call.contains("--scratch-path \(directory.path)/.build-packages/Packages-Containers"), "\(call)")
            #expect(call.contains("-c debug --product ContainerRunner"), "\(call)")
        }
    }

    @Test
    func everyWorkflowBuildLineSaysSo() throws {
        let workflows = Self.root.appending(path: ".github/workflows")
        let files = try FileManager.default.contentsOfDirectory(atPath: workflows.path).filter { $0.hasSuffix(".yml") }
        var invocations = 0
        for file in files {
            let text = try String(contentsOf: workflows.appending(path: file), encoding: .utf8)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                guard line.contains(/\bswift (run|build|test)\b/) else { continue }
                invocations += 1
                #expect(line.contains(Self.flag), "\(file): \(line)")
            }
        }
        #expect(invocations >= 5, "the scan found the workflows' swift invocations")
    }
}
