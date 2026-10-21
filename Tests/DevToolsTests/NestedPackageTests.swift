import Foundation
import Testing

@testable import DevTools

/// The `packages` key of `.vmr.json`: packages of their own that the `build` and `test` steps cover besides the root.
struct NestedPackageTests {
    private static let inner = """
        func double(_ value: Int) -> Int {
          value * 2
        }

        """

    private static let innerTest = """
        import Testing

        @testable import Inner

        @Test func doubles() {
          #expect(double(2) == 4)
        }

        """

    /// The passing root fixture plus a package of its own at `Packages/Inner`, listed in `.vmr.json`.
    private static func files(configured: [String] = ["Packages/Inner"], inner: String = inner, test: String = innerTest) -> [String:
        String]
    {
        GateFixture.variant([
            ".vmr.json": #"{ "packages": [\#(configured.map { "\"\($0)\"" }.joined(separator: ", "))] }"#,
            "Packages/Inner/Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
              name: "Inner",
              platforms: [.macOS(.v14)],
              targets: [
                .target(name: "Inner"),
                .testTarget(name: "InnerTests", dependencies: ["Inner"]),
              ]
            )
            """,
            "Packages/Inner/Package.resolved": #"{ "pins": [], "version": 3 }"#,
            "Packages/Inner/Sources/Inner/Inner.swift": inner,
            "Packages/Inner/Tests/InnerTests/InnerTests.swift": test,
        ])
    }

    private func check(_ steps: [String], files: [String: String]) async throws -> Invocation {
        try await withTemporaryDirectory { directory in
            try write(files, to: directory)
            return try await VMR.vmr(["check"] + steps, in: directory)
        }
    }

    @Test(.timeLimit(.minutes(8)))
    func theBuildAndTestStepsCoverTheNestedPackageInItsOwnScratchDirectory() async throws {
        try await withTemporaryDirectory { directory in
            try write(Self.files(), to: directory)
            let run = try await VMR.vmr(["check", "build", "test"], in: directory)
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.combined.components(separatedBy: "Test run with 1 test").count == 3, "one run for the root, one for Inner")

            let scratch = directory.appending(path: ".build-packages/Packages-Inner")
            #expect(FileManager.default.fileExists(atPath: scratch.path), "the nested package builds under .build-packages")
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "Packages/Inner/.build").path))
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: ".build").path), "the root keeps its own")
        }
    }

    @Test(.timeLimit(.minutes(8)))
    func aFailingTestInTheNestedPackageFailsTheTestStep() async throws {
        let run = try await check(
            ["build", "test"], files: Self.files(test: Self.innerTest.replacingOccurrences(of: "== 4", with: "== 5")))
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.outputLines.contains { $0.hasPrefix("PASS  build (") })
        #expect(run.outputLines.contains { $0.hasPrefix("FAIL  test (") })
        #expect(run.combined.contains("doubles()"), "the failing test is named")
    }

    @Test(.timeLimit(.minutes(8)))
    func aBuildErrorInTheNestedPackageFailsTheBuildStep() async throws {
        let run = try await check(
            ["build"], files: Self.files(inner: GateFixture.doesNotCompile.replacingOccurrences(of: "add", with: "double")))
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.outputLines.contains { $0.hasPrefix("FAIL  build (") })
    }

    @Test(.timeLimit(.minutes(8)))
    func aListedDirectoryWithoutAManifestIsNamed() async throws {
        let run = try await check(["build"], files: Self.files(configured: ["Packages/Absent"]))
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.combined.contains("Packages/Absent has no Package.swift"), "\(run.combined)")
    }

    @Test
    func theScratchDirectoryAndSelectionComeFromThePath() {
        let package = NestedPackage(path: "Packages/Containers")
        #expect(package.scratchPath == ".build-packages/Packages-Containers")
        #expect(package.selection == ["--package-path", "Packages/Containers", "--scratch-path", ".build-packages/Packages-Containers"])
        #expect(NestedPackage(path: "A/B").scratchPath != NestedPackage(path: "B").scratchPath)
    }

    @Test
    func configuredPathsAreNormalizedAndRefusedWhenTheyLeaveTheRoot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vmr-nested-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Packages/One"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appending(path: "Packages/One/Package.swift"))

        #expect(try NestedPackage.resolve(["./Packages//One/"], root: root) == [NestedPackage(path: "Packages/One")])
        #expect(try NestedPackage.resolve([], root: root).isEmpty)
        for refused in ["", ".", "/Packages/One", "../One", "Packages/../One", "Packages/Two"] {
            #expect(throws: ToolError.self, "\(refused)") { try NestedPackage.resolve([refused], root: root) }
        }
        #expect(throws: ToolError.self, "a package listed twice") {
            try NestedPackage.resolve(["Packages/One", "Packages/One/"], root: root)
        }
    }
}
