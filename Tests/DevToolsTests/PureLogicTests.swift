import Foundation
import Testing

@testable import DevTools

/// The small pure pieces behind the commands; the commands themselves are covered end to end.
struct PureLogicTests {
    @Test
    func coverageIsReadFromTheFirstExportEntry() throws {
        let export =
            #"{ "data": [{ "totals": { "lines": { "count": 10, "covered": 7, "percent": 70.5 } } }], "type": "llvm.coverage.json.export" }"#
        #expect(try Coverage.linePercent(fromExport: Data(export.utf8)) == 70.5)
        #expect(throws: ToolError.self) { try Coverage.linePercent(fromExport: Data(#"{ "data": [] }"#.utf8)) }
        #expect(throws: ToolError.self) { try Coverage.linePercent(fromExport: Data("nope".utf8)) }
        #expect(Coverage.line(percent: 77.64, minimum: 55) == "logic-layer line coverage: 77.6% (minimum 55%)")
        #expect(Coverage.describe(minimum: 55.5) == "55.5")
    }

    private static let validCommit = String(repeating: "a", count: 40)
    private static let validDigest = String(repeating: "b", count: 64)

    /// A lock for arcleak with one field replaced.
    private static func lockText(version: String = "0.10.2", commit: String = validCommit, sha256: String = validDigest) -> String {
        "ARCLEAK_VERSION=\(version)\nARCLEAK_COMMIT=\(commit)\nARCLEAK_SHA256_MACOS_ARM64=\(sha256)\n"
    }

    @Test
    func theLockIsKeyValueWithComments() throws {
        let lock = AnalyzerLock(
            text: """
                # comment
                ARCLEAK_VERSION=0.10.2
                ARCLEAK_COMMIT=\(Self.validCommit)

                ARCLEAK_SHA256_MACOS_ARM64="\(Self.validDigest.uppercased())"
                """
        )
        let pin = try lock.pin(for: .arcleak)
        #expect(
            pin == AnalyzerPin(release: AnalyzerTool.arcleak.release, version: "0.10.2", commit: Self.validCommit, sha256: Self.validDigest)
        )
        #expect(pin.archiveName == "arcleak-0.10.2-macos-arm64.tar.gz")
        #expect(throws: ToolError.self) { try lock.pin(for: .dolly) }
    }

    @Test(arguments: [
        (Self.lockText(version: "1.0/../../x"), "ARCLEAK_VERSION '1.0/../../x' is not a version"),
        (Self.lockText(version: "1 0"), "ARCLEAK_VERSION '1 0' is not a version"),
        (Self.lockText(commit: "abc"), "ARCLEAK_COMMIT 'abc' is not 40 lowercase hex digits"),
        (Self.lockText(commit: String(repeating: "A", count: 40)), "is not 40 lowercase hex digits"),
        (Self.lockText(sha256: String(repeating: "g", count: 64)), "is not 64 hex digits"),
        (Self.lockText(sha256: String(repeating: "b", count: 63)), "is not 64 hex digits"),
        (Self.lockText(sha256: String(repeating: "5\u{301}", count: 64)), "is not 64 hex digits"),
        (Self.lockText() + "ARCLEAK_VERSION=0.10.3\n", "assigns ARCLEAK_VERSION more than once"),
    ])
    func aMalformedOrRepeatedLockValueIsRejected(text: String, message: String) {
        let error = #expect(throws: ToolError.self) { try AnalyzerLock(text: text).pin(for: .arcleak) }
        #expect(error?.message.contains(message) == true, "\(error?.message ?? "no error")")
    }

    @Test
    func thisRepositorysLockPinsEveryReleaseWithACommitAndAChecksum() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lock = try AnalyzerLock.load(root: root)
        let hex = Set("0123456789abcdef")
        for release in ReleaseSpec.pinnedReleases {
            let pin = try lock.pin(for: release)
            #expect(pin.commit.count == 40 && pin.commit.allSatisfy(hex.contains), "\(release.name) commit: \(pin.commit)")
            #expect(pin.sha256.count == 64 && pin.sha256.allSatisfy(hex.contains), "\(release.name) checksum: \(pin.sha256)")
        }
    }

    @Test
    func aReleaseSpecNamesItsArchiveItsLayoutAndItsAddress() throws {
        let arcleak = AnalyzerPin(release: AnalyzerTool.arcleak.release, version: "0.10.2", commit: "abc", sha256: "")
        #expect(arcleak.directoryInArchive == "arcleak-0.10.2-macos-arm64")
        #expect(arcleak.release.binaryOverrideVariable == "ARCLEAK_BIN")
        let arcleakAddress = "https://github.com/g-cqd/arcleak/releases/download/v0.10.2/arcleak-0.10.2-macos-arm64.tar.gz"
        #expect(try ReleaseLocation.github.archiveURL(for: arcleak).absoluteString == arcleakAddress)

        let swiftlint = AnalyzerPin(release: .swiftlint, version: "0.65.1", commit: "abc", sha256: "")
        #expect(swiftlint.archiveName == "portable_swiftlint.zip")
        #expect(swiftlint.directoryInArchive == nil, "the binary sits at the root of the zip")
        #expect(swiftlint.release.binaryOverrideVariable == "SWIFTLINT_BIN")
        let swiftlintAddress = "https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip"
        #expect(try ReleaseLocation.github.archiveURL(for: swiftlint).absoluteString == swiftlintAddress)

        let actionlint = AnalyzerPin(release: .actionlint, version: "1.7.12", commit: "abc", sha256: "")
        #expect(actionlint.directoryInArchive == nil)
        #expect(
            try ReleaseLocation.github.archiveURL(for: actionlint).absoluteString
                == "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz")
        let zizmor = AnalyzerPin(release: .zizmor, version: "1.31.1", commit: "abc", sha256: "")
        #expect(
            try ReleaseLocation.github.archiveURL(for: zizmor).absoluteString
                == "https://github.com/zizmorcore/zizmor/releases/download/v1.31.1/zizmor-aarch64-apple-darwin.tar.gz")
    }

    @Test(arguments: [
        ("1.7.12\ninstalled by downloading from release page\nbuilt with go1.26.1 compiler for darwin/arm64\n", "actionlint", "1.7.12"),
        ("zizmor 1.31.1\n", "zizmor", "1.31.1"), ("0.65.1\n", "swiftlint", "0.65.1"), ("  0.10.2  \n", "arcleak", "0.10.2"),
        ("", "dolly", ""),
    ])
    func aVersionReportIsReadFromItsFirstLineWithoutTheToolsName(report: String, name: String, version: String) {
        #expect(AnalyzerInstaller.version(fromReport: report, name: name) == version)
    }

    @Test
    func entitlementsAreComparedByValue() throws {
        let expected = try Entitlements.parse(Data(AppFixture.defaultEntitlements.utf8))
        #expect(Entitlements.problems(effective: expected, expected: expected, isRelease: true).isEmpty)
        let extra = try Entitlements.parse(
            Data(AppFixture.entitlements(["com.apple.security.virtualization": "<false/>", "x.extra": "<string>1</string>"]).utf8)
        )
        let problems = Entitlements.problems(effective: extra, expected: expected, isRelease: true)
        #expect(
            problems == ["entitlement com.apple.security.virtualization is false, expected true", "unexpected entitlement x.extra = '1'"])
        #expect(
            Entitlements.problems(effective: [:], expected: expected, isRelease: false) == [
                "missing entitlement com.apple.security.virtualization"
            ])
        #expect(try Entitlements.parse(Data()).isEmpty)
    }

    @Test
    func theSignedEntitlementsAreJudgedAgainstThePolicyNotOnlyAgainstTheirFile() throws {
        let signed = try Entitlements.parse(
            Data(
                AppFixture.entitlements([
                    "com.apple.security.virtualization": "<true/>",
                    "com.apple.security.cs.allow-jit": "<true/>",
                    "com.apple.security.get-task-allow": "<true/>",
                ]).utf8))
        #expect(
            EntitlementPolicy.problems(in: signed, isRelease: true) == [
                "com.apple.security.cs.allow-jit relaxes the hardened runtime and is not permitted",
                "get-task-allow is present in a release build",
            ])
        #expect(
            EntitlementPolicy.problems(in: signed, isRelease: false) == [
                "com.apple.security.cs.allow-jit relaxes the hardened runtime and is not permitted"
            ], "a debug build may carry get-task-allow")
    }

    @Test
    func thisRepositorysEntitlementFilesSatisfyThePolicy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["VMRunner.entitlements", "VMRunner.hardened.entitlements"] {
            let data = try Data(contentsOf: root.appending(path: "Resources/\(name)"))
            #expect(EntitlementPolicy.problems(in: try Entitlements.parse(data), isRelease: true).isEmpty, "\(name)")
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(EntitlementPolicy.commentProblems(in: text, name: name).isEmpty, "\(name)")
        }
    }

    @Test
    func commentsWithDoubleHyphensAreFoundWithTheirLine() {
        let text = "<plist>\n<!-- fine -->\n<!--\n  two -- hyphens\n-->\n<!-- ends in a hyphen --->\n</plist>"
        #expect(
            EntitlementPolicy.commentProblems(in: text, name: "f.entitlements") == [
                "f.entitlements:4: a double hyphen inside an XML comment (the kernel's entitlement parser rejects it)",
                "f.entitlements: an XML comment ends in a hyphen (the kernel's entitlement parser rejects it)",
            ])
        #expect(EntitlementPolicy.commentProblems(in: "<!-- one --> <!-- two -->", name: "f").isEmpty)
    }

    @Test
    func projectConfigDefaultsAndOverrides() throws {
        let config = try JSONDecoder().decode(
            ProjectConfig.self,
            from: Data(#"{ "lintPaths": ["Sources"], "coverage": { "minimum": 60, "testBundles": ["AppTests"] } }"#.utf8)
        )
        #expect(config.lintPaths == ["Sources"])
        #expect(try config.resolvedCoverageMinimum(environment: [:]) == 60)
        #expect(try config.resolvedCoverageMinimum(environment: ["COVERAGE_MIN": "70"]) == 70)
        #expect(try ProjectConfig().resolvedCoverageMinimum(environment: [:]) == ProjectConfig.defaultCoverageMinimum)
    }
}
