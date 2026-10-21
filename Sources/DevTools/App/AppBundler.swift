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
        try await BuildTools.codesign([
            "--force", "--sign", "-", "--options", "runtime", "--entitlements", entitlementsURL.path, appURL.path,
        ])
        try await BuildTools.verifySignature(of: appURL)
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
        return try await BuildTools.build(arguments).appending(path: Self.productName)
    }

    private func assemble(binary: URL) throws {
        try BuildTools.assemble(
            bundle: appURL, executable: Self.productName, binary: binary, infoPlist: root.appending(path: "Resources/Info.plist"))
    }

    // MARK: Verification

    /// The effective entitlements, read back from the signed bundle, must equal the file used to sign it.
    private func verifyEntitlements() async throws {
        let effective = try await BuildTools.verifyEntitlements(
            of: appURL, expected: try Entitlements.load(fileAt: entitlementsURL), isRelease: options.configuration == .release,
            expectation: entitlementsURL.lastPathComponent)
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
