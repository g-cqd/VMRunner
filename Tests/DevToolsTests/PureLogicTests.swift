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

    @Test
    func theLockIsKeyValueWithComments() throws {
        let lock = AnalyzerLock(
            text: """
                # comment
                ARCLEAK_VERSION=0.10.2
                ARCLEAK_COMMIT=abc

                ARCLEAK_SHA256_MACOS_ARM64="DEADBEEF"
                """
        )
        let pin = try lock.pin(for: .arcleak)
        #expect(pin == AnalyzerPin(tool: .arcleak, version: "0.10.2", commit: "abc", sha256: "deadbeef"))
        #expect(pin.archiveName == "arcleak-0.10.2-macos-arm64.tar.gz")
        #expect(throws: ToolError.self) { try lock.pin(for: .dolly) }
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
