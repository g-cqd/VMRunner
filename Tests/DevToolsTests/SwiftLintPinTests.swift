import Foundation
import Testing

@testable import DevTools

/// The pinned SwiftLint end to end: `vmr check swiftlint` against a local fixture release whose SwiftLint is a fake.
struct SwiftLintPinTests {
    /// The fixture, with the package manifest the gate needs. `SWIFTLINT_BIN` is emptied so the pin is what resolves.
    private func check(_ fixture: AnalyzerFixture, environment: [String: String] = [:]) async throws -> Invocation {
        try write(["Package.swift": "// swift-tools-version: 6.0\n"], to: fixture.root)
        return try await fixture.vmr(["check", "swiftlint"], environment: ["SWIFTLINT_BIN": ""].merging(environment) { _, new in new })
    }

    @Test
    func theGateStepInstallsVerifiesAndRunsThePinnedRelease() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let first = try await check(fixture)
            #expect(first.status == 0, "\(first.combined)")
            #expect(first.output.contains("installing swiftlint 1.2.3 from file://"), "\(first.output)")
            #expect(first.outputLines.contains { $0.hasPrefix("PASS  swiftlint (") })
            let binary = fixture.root.appending(path: ".tools/swiftlint-1.2.3/swiftlint")
            #expect(FileManager.default.isExecutableFile(atPath: binary.path))
            #expect(fixture.loggedCalls(of: "swiftlint") == ["swiftlint --version", "swiftlint lint --quiet"], "the probe, then the lint")

            let second = try await check(fixture)
            #expect(second.status == 0, "\(second.combined)")
            #expect(!second.output.contains("installing "), "an installed release is reused")
            #expect(fixture.loggedCalls(of: "swiftlint").count == 3, "the second run only lints")
        }
    }

    @Test
    func aTamperedArchiveIsRefusedAndNeverExecuted() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base, tampered: ["swiftlint"])
            let run = try await check(fixture)
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("swiftlint 1.2.3: SHA-256 mismatch"), "\(run.error)")
            #expect(run.error.contains("refusing to run it"))
            #expect(run.outputLines.contains { $0.hasPrefix("FAIL  swiftlint (") })
            #expect(fixture.loggedCalls(of: "swiftlint").isEmpty, "the tampered binary must not run, not even for --version")
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".tools/swiftlint-1.2.3").path))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: ".tools").path)
            #expect(!leftovers.contains { $0.hasPrefix(".download") }, "the download scratch directory is removed")
        }
    }

    @Test
    func aBinaryThatReportsAnotherVersionThanPinnedIsNotInstalled() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let run = try await check(fixture, environment: ["FAKE_ANALYZER_VERSION": "9.9.9"])
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("swiftlint binary reports '9.9.9', expected '1.2.3'"), "\(run.error)")
            #expect(fixture.loggedCalls(of: "swiftlint") == ["swiftlint --version"], "only the probe ran, never the lint")
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".tools/swiftlint-1.2.3").path))
        }
    }

    @Test
    func aLockWithoutAKeyFailsTheStepNamingIt() async throws {
        try await withTemporaryDirectory { base in
            let versionAndCommitOnly = "SWIFTLINT_VERSION=1.2.3\nSWIFTLINT_COMMIT=\(String(repeating: "d", count: 40))\n"
            let fixture = try await AnalyzerFixture.make(in: base, lockText: versionAndCommitOnly)
            let run = try await check(fixture)
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("Scripts/analyzers.lock has no SWIFTLINT_SHA256_MACOS_ARM64"), "\(run.error)")
            #expect(fixture.loggedCalls(of: "swiftlint").isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".tools").path), "nothing was downloaded")
        }
    }

    @Test
    func aBinaryOverrideReplacesThePinnedDownload() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let own = base.appending(path: "own", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: VMR.binary(named: "FakeAnalyzer"), to: own.appending(path: "swiftlint"))

            let run = try await check(fixture, environment: ["SWIFTLINT_BIN": own.appending(path: "swiftlint").path])
            #expect(run.status == 0, "\(run.combined)")
            #expect(!run.output.contains("installing "))
            #expect(
                fixture.loggedCalls(of: "swiftlint") == ["swiftlint lint --quiet"], "an override is run as it is, without a version probe")
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".tools").path))
        }
    }
}
