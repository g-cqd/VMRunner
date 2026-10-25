import Foundation
import Testing

/// `vmr build-app` end to end: a real build, a real ad-hoc signature, real `codesign` verification.
struct BuildAppTests {
    private func buildApp(_ arguments: [String], files: [String: String] = AppFixture.files()) async throws -> (Invocation, URL?) {
        try await withTemporaryDirectory { directory in
            try write(files, to: directory)
            let runner = try AppFixture.runner(in: directory)
            let run = try await VMR.vmr(["build-app", "--container-runner", runner.path] + arguments, in: directory)
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
        #expect(FileManager.default.isExecutableFile(atPath: app.appending(path: "Contents/Helpers/ContainerRunner").path))
    }

    @Test(.timeLimit(.minutes(8)))
    func aReleaseBuildIsSignedVerifiedAndReported() async throws {
        let (run, app) = try await buildApp([])
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.outputLines.contains("entitlements OK (com.apple.security.virtualization)"), "\(run.output)")
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
        #expect(run.error.contains("entitlement policy FAILED:"), "refused from the files, before a build: \(run.error)")
        #expect(
            run.error.contains("  - VMRunner.entitlements: get-task-allow is present in a release build"), "\(run.error)")
        #expect(app == nil)
    }

    /// Runs `build-app` over a fixture whose entitlement files are given, and returns the run and whether anything was built.
    private func refusedBeforeBuilding(
        _ arguments: [String] = [],
        default defaultFile: String = AppFixture.defaultEntitlements,
        hardened hardenedFile: String = AppFixture.hardenedEntitlements,
        runner runnerFile: String = AppFixture.runnerEntitlements
    ) async throws -> (run: Invocation, built: Bool) {
        try await withTemporaryDirectory { directory in
            try write(
                AppFixture.files(defaultEntitlements: defaultFile, hardenedEntitlements: hardenedFile, runnerEntitlements: runnerFile),
                to: directory)
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

    @Test(arguments: [
        (
            "com.apple.security.device.audio-input",
            "com.apple.security.device.audio-input is not in the entitlement allowlist"
        ),
        ("com.apple.security.get-task-allow", "get-task-allow is present in a release build"),
        ("com.apple.security.cs.allow-jit", "com.apple.security.cs.allow-jit relaxes the hardened runtime and is not permitted"),
    ])
    func anExtraEntitlementInTheRunnersFileIsRefusedBeforeBuildingEvenWhenTheAppMayCarryIt(key: String, message: String) async throws {
        let extra = AppFixture.entitlements(["com.apple.security.virtualization": "<true/>", key: "<true/>"])
        let (run, built) = try await refusedBeforeBuilding(["debug"], runner: extra)
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.error.contains("  - ContainerRunner.entitlements: \(message)"), "\(run.error)")
        #expect(!built, "the policy is checked on the file before anything is built")
    }

    @Test
    func aRunnerFileWithoutVirtualizationIsRefusedBeforeBuilding() async throws {
        let (run, built) = try await refusedBeforeBuilding(runner: AppFixture.entitlements([:]))
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.error.contains("ContainerRunner.entitlements must grant com.apple.security.virtualization"), "\(run.error)")
        #expect(!built)
    }

    @Test(.timeLimit(.minutes(8)))
    func theRunnerIsSignedAlongsideItsOwnEntitlementsAndSealedByTheApp() async throws {
        try await withTemporaryDirectory { directory in
            try write(AppFixture.files(), to: directory)
            let source = try AppFixture.runner(in: directory)
            let run = try await VMR.vmr(["build-app", "--hardened", "--container-runner", source.path], in: directory)
            #expect(run.status == 0, "\(run.combined)")
            let app = directory.appending(path: "build/VMRunner.app")
            let runner = app.appending(path: "Contents/Helpers/ContainerRunner")
            #expect(run.outputLines.contains("runner: Signed \(runner.path)"), "\(run.output)")

            // The app is hardened; the runner keeps virtualization alone, with the hardened runtime, as signed on its own.
            let entitlements = try await VMR.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", runner.path], in: directory)
            #expect(entitlements.output.contains("com.apple.security.virtualization"), "\(entitlements.combined)")
            #expect(!entitlements.output.contains("hardened-process"), "\(entitlements.output)")
            let flags = try await VMR.run("/usr/bin/codesign", ["-dv", "--verbose=4", runner.path], in: directory)
            #expect((flags.error + flags.output).contains("(adhoc,runtime)"), "\(flags.combined)")

            // The runner was copied: the executable it came from is as it was, and is not the one that was signed.
            let original = try await VMR.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", source.path], in: directory)
            #expect(!original.output.contains("virtualization"), "\(original.output)")

            // The app seals the runner: a runner signed again after the app breaks the app's signature.
            let resign = try await VMR.run("/usr/bin/codesign", ["--force", "--sign", "-", runner.path], in: directory)
            #expect(resign.status == 0, "\(resign.combined)")
            let broken = try await VMR.run("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path], in: directory)
            #expect(broken.status != 0, "signing the runner after the app must not leave a valid app: \(broken.combined)")
        }
    }

    @Test
    func aRunnerThatIsNotAnExecutableIsNamedAndNothingIsAssembled() async throws {
        try await withTemporaryDirectory { directory in
            try write(AppFixture.files(), to: directory)
            let missing = directory.appending(path: "absent")
            let run = try await VMR.vmr(["build-app", "--container-runner", missing.path], in: directory)
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("\(missing.path) is not an executable"), "\(run.error)")
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "build").path), "no bundle was started")
        }
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
