import Foundation
import Testing

@testable import DevTools

/// `vmr analyzers` end to end against a local fixture release of fake analyzers.
struct AnalyzersTests {
    private static let commonArguments = "analyze Sources Tests --relative-to . --config"

    @Test
    func installsVerifiesAndRunsEveryToolWithItsConfigAndBaseline() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            try write([".deadwood-baseline.json": "{}"], to: fixture.root)

            let first = try await fixture.vmr(["analyzers"])
            #expect(first.status == 0, "\(first.combined)")
            for tool in AnalyzerTool.allCases {
                #expect(first.output.contains("installing \(tool.rawValue) 1.2.3 from file://"))
                #expect(first.output.contains("PASS  \(tool.rawValue)\n"))
                let binary = fixture.root.appending(path: ".tools/\(tool.rawValue)-1.2.3/\(tool.rawValue)")
                #expect(FileManager.default.isExecutableFile(atPath: binary.path))
            }

            // Install probes the version once; the analysis arguments follow the former script exactly.
            let cache = ".build-analyzers"
            #expect(
                fixture.loggedCalls(of: .arcleak) == [
                    "arcleak --version",
                    "arcleak \(Self.commonArguments) .arcleak.json --cache-path \(cache)/arcleak-facts.json --strict",
                ]
            )
            #expect(
                fixture.loggedCalls(of: .dolly) == [
                    "dolly --version", "dolly \(Self.commonArguments) .dolly.json --cache-path \(cache)/dolly-facts.json",
                ]
            )
            #expect(
                fixture.loggedCalls(of: .deadwood) == [
                    "deadwood --version",
                    "deadwood \(Self.commonArguments) .deadwood.json --cache-path \(cache)/deadwood-facts.json"
                        + " --strict --baseline .deadwood-baseline.json",
                ]
            )

            let second = try await fixture.vmr(["analyzers"])
            #expect(second.status == 0, "\(second.combined)")
            #expect(!second.output.contains("installing "), "an installed release is reused")
            #expect(fixture.loggedCalls(of: .arcleak).count == 3, "the second run only analyzes")
        }
    }

    @Test
    func aTamperedArchiveIsRefusedAndNeverExecuted() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base, tampered: ["arcleak"])
            let run = try await fixture.vmr(["analyzers"])
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("arcleak 1.2.3: SHA-256 mismatch"), "\(run.error)")
            #expect(run.error.contains("refusing to run it"))
            #expect(run.output.contains("FAIL  arcleak: not installed"))
            #expect(fixture.loggedCalls(of: .arcleak).isEmpty, "the tampered binary must not run, not even for --version")
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".tools/arcleak-1.2.3").path))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: ".tools").path)
            #expect(!leftovers.contains { $0.hasPrefix(".download") }, "the download scratch directory is removed")
            // The untampered tools are unaffected.
            #expect(run.output.contains("PASS  dolly\n") && run.output.contains("PASS  deadwood\n"))
        }
    }

    @Test(arguments: [
        (0 as Int32, "PASS  arcleak\n"),
        (1, "FAIL  arcleak: findings (exit 1)"),
        (64, "FAIL  arcleak: the analyzer itself failed (exit 64:"),
        (70, "FAIL  arcleak: the analyzer itself failed (exit 70:"),
        (78, "FAIL  arcleak: the analyzer itself failed (exit 78: 64 usage, 70 nothing analyzed, 78 bad config or baseline)"),
    ])
    func mapsTheAnalyzersExitCodes(code: Int32, expected: String) async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let run = try await fixture.vmr(["analyzers", "arcleak"], environment: ["FAKE_EXIT_ARCLEAK": "\(code)"])
            #expect(run.status == (code == 0 ? 0 : 1), "\(run.combined)")
            #expect(run.output.contains(expected), "\(run.output)")
            #expect(!run.output.contains("dolly"), "only the named tool runs")
        }
    }

    @Test
    func baselineWritesTheDefaultToolsOrTheNamedOnes() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let defaults = try await fixture.vmr(["analyzers", "baseline"])
            #expect(defaults.status == 0, "\(defaults.combined)")
            let root = fixture.root
            #expect(FileManager.default.fileExists(atPath: root.appending(path: ".dolly-baseline.json").path))
            #expect(FileManager.default.fileExists(atPath: root.appending(path: ".deadwood-baseline.json").path))
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".arcleak-baseline.json").path))
            let dolly = try String(contentsOf: root.appending(path: ".dolly-baseline.json"), encoding: .utf8)
            #expect(dolly.contains("\"tool\":\"dolly\""))
            #expect(
                fixture.loggedCalls(of: .dolly).last
                    == "dolly \(Self.commonArguments) .dolly.json --cache-path .build-analyzers/dolly-facts.json"
                    + " --write-baseline .dolly-baseline.json"
            )

            let named = try await fixture.vmr(["analyzers", "baseline", "arcleak"])
            #expect(named.status == 0, "\(named.combined)")
            #expect(FileManager.default.fileExists(atPath: root.appending(path: ".arcleak-baseline.json").path))
        }
    }

    @Test
    func aBinaryThatReportsAnotherVersionThanPinnedIsNotInstalled() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let run = try await fixture.vmr(["analyzers", "install", "dolly"], environment: ["FAKE_ANALYZER_VERSION": "9.9.9"])
            #expect(run.status == 1)
            #expect(run.error.contains("dolly binary reports '9.9.9', expected '1.2.3'"), "\(run.error)")
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".tools/dolly-1.2.3").path))
        }
    }

    @Test
    func installOnlyDownloadsAndVersionsListsThePins() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let install = try await fixture.vmr(["analyzers", "install"])
            #expect(install.status == 0, "\(install.combined)")
            #expect(fixture.loggedCalls(of: .deadwood) == ["deadwood --version"], "install must not analyze")

            let versions = try await fixture.vmr(["analyzers", "versions"])
            #expect(
                versions.outputLines.dropLast()
                    == ReleaseSpec.pinnedReleases.map { "\($0.name) 1.2.3 (commit \(AnalyzerFixture.commit(of: $0)))" })
            #expect(versions.output.contains("swiftlint 1.2.3 (commit \(String(repeating: "d", count: 40)))"), "SwiftLint is listed")
        }
    }

    @Test
    func aBinaryOverrideReplacesThePinnedDownload() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let own = base.appending(path: "own", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: VMR.binary(named: "FakeAnalyzer"), to: own.appending(path: "dolly"))

            let run = try await fixture.vmr(["analyzers", "dolly"], environment: ["DOLLY_BIN": own.appending(path: "dolly").path])
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output.contains("--- dolly 1.2.3: analyze"), "an override reports the version the binary prints")
            #expect(!run.output.contains("installing "))
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".tools").path))
        }
    }

    @Test
    func aScriptPlantedInTheToolsDirectoryIsReplacedNotRun() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            try fixture.plantScript(named: "arcleak")
            let run = try await fixture.vmr(["analyzers", "arcleak"])
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output.contains("installing arcleak 1.2.3 from file://"), "\(run.output)")
            #expect(fixture.plantedRuns == 0, "the planted script must never execute")
            #expect(fixture.loggedCalls(of: .arcleak).first == "arcleak --version")
        }
    }

    @Test
    func aCommittedBinaryWithAMatchingStampIsRefused() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let first = try await fixture.vmr(["analyzers", "install", "arcleak"])
            #expect(first.status == 0, "\(first.combined)")
            try fixture.plantScript(named: "arcleak")
            try fixture.forgeStamp(for: AnalyzerTool.arcleak.release)
            try await fixture.trackTools()

            let run = try await fixture.vmr(["analyzers", "arcleak"])
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("git tracks files under"), "\(run.error)")
            #expect(run.output.contains("FAIL  arcleak: not installed"))
            #expect(fixture.plantedRuns == 0)
        }
    }

    @Test
    func anOverrideUnderCIIsWarnedAbout() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let own = base.appending(path: "own", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: VMR.binary(named: "FakeAnalyzer"), to: own.appending(path: "dolly"))
            let environment = ["DOLLY_BIN": own.appending(path: "dolly").path]

            let quiet = try await fixture.vmr(["analyzers", "dolly"], environment: environment)
            #expect(!quiet.error.contains("WARNING"), "\(quiet.error)")
            let loud = try await fixture.vmr(["analyzers", "dolly"], environment: environment.merging(["CI": "true"]) { _, new in new })
            #expect(loud.status == 0, "\(loud.combined)")
            #expect(loud.error.contains("WARNING: CI is set and DOLLY_BIN="), "\(loud.error)")
        }
    }

    @Test
    func theAnalyzersGateStepUsesTheSameRunner() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            try write(["Package.swift": "// swift-tools-version: 6.0\n"], to: fixture.root)
            let passing = try await fixture.vmr(["check", "analyzers"])
            #expect(passing.status == 0, "\(passing.combined)")
            #expect(passing.outputLines.contains { $0.hasPrefix("PASS  analyzers (") })

            let failing = try await fixture.vmr(["check", "analyzers"], environment: ["FAKE_EXIT_DOLLY": "1"])
            #expect(failing.status == 1)
            #expect(failing.output.contains("FAIL  dolly: findings (exit 1)"))
            #expect(failing.outputLines.contains { $0.hasPrefix("FAIL  analyzers (") })
        }
    }

    @Test
    func rejectsBadInput() async throws {
        try await withTemporaryDirectory { base in
            let fixture = try await AnalyzerFixture.make(in: base)
            let unknownTool = try await fixture.vmr(["analyzers", "swiftlint"])
            #expect(unknownTool.status == 64)
            #expect(unknownTool.error.contains("'swiftlint' is invalid"), "\(unknownTool.error)")

            let insecure = try await fixture.vmr(
                ["analyzers", "install"], environment: ["VMR_ANALYZERS_BASE_URL": "http://example.com/releases"])
            #expect(insecure.status == 1)
            #expect(insecure.error.contains("must be a file: or https: URL"), "\(insecure.error)")

            let missingArchive = try await fixture.vmr(
                ["analyzers", "install", "dolly"], environment: ["VMR_ANALYZERS_BASE_URL": base.appending(path: "nowhere").absoluteString])
            #expect(missingArchive.status == 1)
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".tools/dolly-1.2.3").path))
        }
    }
}
