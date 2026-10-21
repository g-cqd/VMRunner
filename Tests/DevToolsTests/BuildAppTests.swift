import Foundation
import Testing

/// `vmr build-app` end to end: a real build, a real ad-hoc signature, real `codesign` verification.
struct BuildAppTests {
    private func buildApp(_ arguments: [String], files: [String: String] = AppFixture.files()) async throws -> (Invocation, URL?) {
        try await withTemporaryDirectory { directory in
            try write(files, to: directory)
            let run = try await VMR.vmr(["build-app"] + arguments, in: directory)
            let app = directory.appending(path: "build/VMRunner.app")
            // The directory is removed when this closure returns, so everything to check about the bundle happens here.
            if run.status == 0 {
                try await Self.expectIndependentlyVerifiable(app, in: directory)
            }
            return (run, run.status == 0 ? app : nil)
        }
    }

    /// Verifies the bundle with `codesign` itself, not through vmr.
    private static func expectIndependentlyVerifiable(_ app: URL, in directory: URL) async throws {
        let verify = try await VMR.run("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path], in: directory)
        #expect(verify.status == 0, "\(verify.combined)")
        #expect(FileManager.default.isExecutableFile(atPath: app.appending(path: "Contents/MacOS/VMRunner").path))
        #expect(FileManager.default.fileExists(atPath: app.appending(path: "Contents/Info.plist").path))
    }

    @Test(.timeLimit(.minutes(8)))
    func aReleaseBuildIsSignedVerifiedAndReported() async throws {
        let (run, app) = try await buildApp([])
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.output.contains("entitlements OK (com.apple.security.virtualization)"), "\(run.output)")
        #expect(run.outputLines.contains { $0.hasPrefix("code signature: flags=0x") && $0.contains("runtime") }, "\(run.output)")
        #expect(run.outputLines.contains("architecture:   arm64"))
        #expect(run.output.contains("/build/VMRunner.app\n"))
        #expect(!run.output.contains("profile:"), "no hardened profile line without --hardened")
        #expect(app != nil)
    }

    @Test(.timeLimit(.minutes(8)))
    func aReleaseBuildWhoseEntitlementsGainGetTaskAllowFails() async throws {
        let withTaskAllow = AppFixture.entitlements([
            "com.apple.security.virtualization": "<true/>",
            "com.apple.security.get-task-allow": "<true/>",
        ])
        let (run, app) = try await buildApp(
            ["release"],
            files: AppFixture.files(defaultEntitlements: withTaskAllow, hardenedEntitlements: withTaskAllow)
        )
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.error.contains("entitlement check FAILED:"))
        #expect(run.error.contains("  - get-task-allow is present in a release build"), "\(run.error)")
        #expect(app == nil)
    }

    @Test(.timeLimit(.minutes(8)))
    func aDebugBuildMayKeepGetTaskAllow() async throws {
        let withTaskAllow = AppFixture.entitlements([
            "com.apple.security.virtualization": "<true/>",
            "com.apple.security.get-task-allow": "<true/>",
        ])
        // The hardened file has to stay a superset of the default one, so it carries get-task-allow too.
        let files = AppFixture.files(defaultEntitlements: withTaskAllow, hardenedEntitlements: withTaskAllow)
        let (run, _) = try await buildApp(["--debug"], files: files)
        #expect(run.status == 0, "\(run.combined)")
        #expect(
            run.output.contains("entitlements OK (com.apple.security.get-task-allow, com.apple.security.virtualization)"), "\(run.output)")
    }

    @Test(.timeLimit(.minutes(8)))
    func hardenedSignsWithTheHardenedEntitlements() async throws {
        let (run, _) = try await buildApp(["release", "--hardened"])
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.output.contains("com.apple.security.hardened-process"), "\(run.output)")
        #expect(run.outputLines.contains("profile:        hardened (Enhanced Security entitlements)"))
    }

    @Test(.timeLimit(.minutes(8)))
    func theHardenedFileMustKeepEverythingTheDefaultFileGrants() async throws {
        let drifted = AppFixture.entitlements(["com.apple.security.hardened-process": "<true/>"])
        let (run, _) = try await buildApp(["--hardened"], files: AppFixture.files(hardenedEntitlements: drifted))
        #expect(run.status == 1, "\(run.combined)")
        #expect(
            run.error.contains("VMRunner.hardened.entitlements drifted from VMRunner.entitlements: com.apple.security.virtualization"),
            "\(run.error)"
        )
    }

    @Test(.timeLimit(.minutes(8)))
    func anArm64eBuildReportsItsArchitecture() async throws {
        let (run, _) = try await buildApp(["debug", "--arm64e"])
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.outputLines.contains("architecture:   arm64e"), "\(run.output)")
    }

    @Test
    func rejectsUnknownArguments() async throws {
        try await withTemporaryDirectory { directory in
            try write(AppFixture.files(), to: directory)
            let run = try await VMR.vmr(["build-app", "--sign-with-my-cert"], in: directory)
            #expect(run.status == 64)
            #expect(run.error.lowercased().contains("unknown option '--sign-with-my-cert'"), "\(run.error)")
        }
    }
}
