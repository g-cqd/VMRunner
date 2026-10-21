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
    func onlyTheAppProductIsBuilt() async throws {
        var files = AppFixture.files()
        let targets = #"targets: [.executableTarget(name: "VMRunner")]"#
        files["Package.swift"] = files["Package.swift"]?.replacingOccurrences(
            of: targets, with: #"targets: [.executableTarget(name: "VMRunner"), .executableTarget(name: "Other")]"#)
        files["Sources/Other/main.swift"] = "this does not compile\n"
        let (run, app) = try await buildApp([], files: files)
        #expect(run.status == 0, "a target that is not the app must not be built: \(run.combined)")
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
        #expect(run.error.contains("entitlement policy FAILED:"), "refused from the files, before a build: \(run.error)")
        #expect(
            run.error.contains("  - VMRunner.entitlements: get-task-allow is present in a release build"), "\(run.error)")
        #expect(app == nil)
    }

    /// Runs `build-app` over a fixture whose two entitlement files are given, and returns the run and whether anything was built.
    private func refusedBeforeBuilding(
        _ arguments: [String] = [],
        default defaultFile: String,
        hardened hardenedFile: String
    ) async throws -> (run: Invocation, built: Bool) {
        try await withTemporaryDirectory { directory in
            try write(AppFixture.files(defaultEntitlements: defaultFile, hardenedEntitlements: hardenedFile), to: directory)
            let run = try await VMR.vmr(["build-app"] + arguments, in: directory)
            let fileManager = FileManager.default
            let built =
                fileManager.fileExists(atPath: directory.appending(path: ".build").path)
                || fileManager.fileExists(atPath: directory.appending(path: "build").path)
            return (run, built)
        }
    }

    @Test(arguments: ["release", "debug"])
    func aRelaxationInBothFilesIsRefusedEvenThoughSignatureAndFileWouldAgree(configuration: String) async throws {
        let relaxed = AppFixture.entitlements([
            "com.apple.security.virtualization": "<true/>",
            "com.apple.security.cs.disable-library-validation": "<true/>",
        ])
        let (run, built) = try await refusedBeforeBuilding([configuration], default: relaxed, hardened: relaxed)
        #expect(run.status == 1, "\(run.combined)")
        for file in ["VMRunner.entitlements", "VMRunner.hardened.entitlements"] {
            let line = "  - \(file): com.apple.security.cs.disable-library-validation relaxes the hardened runtime and is not permitted"
            #expect(run.error.contains(line), "\(run.error)")
        }
        #expect(!built, "the policy is checked on the files before anything is built")
    }

    @Test(arguments: [
        ("com.apple.security.network.client", "<true/>", "com.apple.security.network.client is not in the entitlement allowlist"),
        ("com.apple.security.temporary-exception.mach-lookup.global-name", "<true/>", "is a sandbox exception and is not permitted"),
        ("com.apple.security.virtualization", "<false/>", "com.apple.security.virtualization is false; the policy allows only true"),
    ])
    func anEntitlementOutsideTheAllowlistOrWithAnotherValueIsRefused(key: String, value: String, message: String) async throws {
        let file = AppFixture.entitlements(["com.apple.security.virtualization": "<true/>"].merging([key: value]) { _, new in new })
        let (run, built) = try await refusedBeforeBuilding(default: file, hardened: file)
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.error.contains(message), "\(run.error)")
        #expect(!built)
    }

    @Test
    func aDoubleHyphenInsideAnXMLCommentIsRefused() async throws {
        let commented = AppFixture.defaultEntitlements.replacingOccurrences(
            of: "<dict>", with: "<dict>\n    <!-- never write -- inside a comment -->")
        let (run, built) = try await refusedBeforeBuilding(default: AppFixture.defaultEntitlements, hardened: commented)
        #expect(run.status == 1, "\(run.combined)")
        #expect(
            run.error.contains("VMRunner.hardened.entitlements:5: a double hyphen inside an XML comment"), "\(run.error)")
        #expect(!built)
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
