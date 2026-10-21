import Foundation

/// Builds `build/VMRunner.app`, ad-hoc signs it with the hardened runtime and the entitlements it needs, then
/// verifies the result: signature, effective entitlements, hardened-runtime flag and architecture.
struct AppBundler {
    enum Configuration: String, CaseIterable {
        case debug
        case release
    }

    struct Options {
        var configuration = Configuration.release
        /// Sign with `VMRunner.hardened.entitlements` (Apple's Enhanced Security) instead of the default file.
        var hardened = false
        /// Build an arm64e (pointer authentication) executable, in its own scratch path so the default build is untouched.
        var arm64e = false
    }

    static let productName = "VMRunner"

    let root: URL
    let options: Options

    private var appURL: URL { root.appending(path: "build/\(Self.productName).app", directoryHint: .isDirectory) }
    private var executableURL: URL { appURL.appending(path: "Contents/MacOS/\(Self.productName)") }
    private var defaultEntitlementsURL: URL { root.appending(path: "Resources/\(Self.productName).entitlements") }
    private var hardenedEntitlementsURL: URL { root.appending(path: "Resources/\(Self.productName).hardened.entitlements") }
    private var entitlementsURL: URL { options.hardened ? hardenedEntitlementsURL : defaultEntitlementsURL }

    func run() async throws {
        // Cheap file checks first, so a drifted entitlements file fails before a long build.
        try verifyHardenedSuperset()
        let binary = try await compile()
        try assemble(binary: binary)
        try await codesign(["--force", "--sign", "-", "--options", "runtime", "--entitlements", entitlementsURL.path, appURL.path])
        try await verifySignature()
        try await verifyEntitlements()
        let signature = try await verifyHardenedRuntime()
        try await report(signature: signature)
    }

    // MARK: Build and assemble

    private func compile() async throws -> URL {
        var arguments = ["--package-path", root.path, "-c", options.configuration.rawValue]
        if options.arm64e {
            arguments += ["--arch", "arm64e", "--scratch-path", root.appending(path: ".build-arm64e").path]
        }
        let build = try await ProcessRunner.run(CommandSpec(executable: "swift", arguments: ["build"] + arguments), output: .inherit)
        guard build.succeeded else { throw ToolError("swift build failed", status: build.status) }

        let path = try await ProcessRunner.run(CommandSpec(executable: "swift", arguments: ["build"] + arguments + ["--show-bin-path"]))
        guard path.succeeded, let line = path.standardOutput.split(whereSeparator: \.isNewline).last else {
            throw ToolError("swift build --show-bin-path failed: \(path.standardError)")
        }
        return URL(fileURLWithPath: String(line)).appending(path: Self.productName)
    }

    private func assemble(binary: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: appURL)
        try fileManager.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: binary, to: executableURL)
        let infoPlist = root.appending(path: "Resources/Info.plist")
        guard fileManager.fileExists(atPath: infoPlist.path) else { throw ToolError("cannot read \(infoPlist.path)") }
        try fileManager.copyItem(at: infoPlist, to: appURL.appending(path: "Contents/Info.plist"))
    }

    // MARK: Verification

    private func codesign(_ arguments: [String]) async throws {
        let result = try await ProcessRunner.run(CommandSpec(executable: "codesign", arguments: arguments), output: .inherit)
        guard result.succeeded else { throw ToolError("codesign \(arguments[0]) failed", status: result.status) }
    }

    private func verifySignature() async throws {
        try await codesign(["--verify", "--strict", "--deep", "--verbose=1", appURL.path])
    }

    /// The effective entitlements, read back from the signed bundle, must equal the file used to sign it.
    private func verifyEntitlements() async throws {
        let result = try await ProcessRunner.run(
            CommandSpec(executable: "codesign", arguments: ["-d", "--entitlements", ":-", appURL.path]))
        guard result.succeeded else { throw ToolError("codesign could not read the entitlements: \(result.standardError)") }
        let effective = try Entitlements.parse(Data(result.standardOutput.utf8))
        let expected = try Entitlements.load(fileAt: entitlementsURL)
        let problems = Entitlements.problems(effective: effective, expected: expected, isRelease: options.configuration == .release)
        guard problems.isEmpty else {
            Output.err("entitlement check FAILED:")
            for problem in problems {
                Output.err("  - \(problem)")
            }
            throw ToolError("the signed entitlements differ from \(entitlementsURL.lastPathComponent)")
        }
        Output.out("entitlements OK (\(effective.keys.sorted().joined(separator: ", ")))")
    }

    /// The hardened file must stay a superset of the default one, so `--hardened` never loses a capability.
    private func verifyHardenedSuperset() throws {
        let lost = Entitlements.lostByHardened(
            base: try Entitlements.load(fileAt: defaultEntitlementsURL),
            hardened: try Entitlements.load(fileAt: hardenedEntitlementsURL)
        )
        if !lost.isEmpty {
            let hardened = hardenedEntitlementsURL.lastPathComponent
            throw ToolError("\(hardened) drifted from \(defaultEntitlementsURL.lastPathComponent): \(lost.joined(separator: ", "))")
        }
    }

    /// `codesign -dv` output, which must show the `runtime` flag.
    private func verifyHardenedRuntime() async throws -> String {
        let result = try await ProcessRunner.run(CommandSpec(executable: "codesign", arguments: ["-dv", "--verbose=4", appURL.path]))
        let output = result.standardError + result.standardOutput
        guard output.contains(#/flags=0x[0-9a-f]+\([^)]*runtime/#) else {
            throw ToolError("hardened runtime flag is missing from the signature")
        }
        return output
    }

    private func report(signature: String) async throws {
        let directory = signature.split(whereSeparator: \.isNewline).first { $0.hasPrefix("CodeDirectory") }
        if let directory, let flags = directory.range(of: "flags=") {
            Output.out("code signature: \(directory[flags.lowerBound...])")
        }
        let architectures = try await ProcessRunner.run(CommandSpec(executable: "lipo", arguments: ["-archs", executableURL.path]))
        Output.out("architecture:   \(architectures.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        if options.hardened {
            Output.out("profile:        hardened (Enhanced Security entitlements)")
        }
        Output.out("Built \(appURL.path)")
    }
}
