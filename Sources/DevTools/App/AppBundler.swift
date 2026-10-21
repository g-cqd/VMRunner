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
        // Cheap file checks first, so a drifted or over-privileged entitlements file fails before a long build.
        try verifyEntitlementFiles()
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
        // Only the app: the package also holds targets that link packages the app must never pull in (the container spike).
        var arguments = ["--package-path", root.path, "-c", options.configuration.rawValue, "--product", Self.productName]
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

    /// Both entitlement files must satisfy `EntitlementPolicy` and carry no double hyphen inside an XML comment, whichever
    /// one this run signs with: a file that agrees with its own signature proves nothing about what it grants.
    private func verifyEntitlementFiles() throws {
        let isRelease = options.configuration == .release
        var problems: [String] = []
        for url in [defaultEntitlementsURL, hardenedEntitlementsURL] {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                throw ToolError("cannot read \(url.path)")
            }
            problems += EntitlementPolicy.commentProblems(in: text, name: name)
            problems += EntitlementPolicy.problems(in: try Entitlements.parse(data), isRelease: isRelease).map { "\(name): \($0)" }
        }
        guard problems.isEmpty else {
            Output.err("entitlement policy FAILED:")
            for problem in problems {
                Output.err("  - \(problem)")
            }
            throw ToolError("the entitlement files break the policy in EntitlementPolicy.swift; nothing was built")
        }
    }

    /// The effective entitlements, read back from the signed bundle, must equal the file used to sign it and satisfy the policy.
    private func verifyEntitlements() async throws {
        let isRelease = options.configuration == .release
        let effective = try await BuildTools.verifyEntitlements(
            of: appURL, expected: try Entitlements.load(fileAt: entitlementsURL), isRelease: isRelease,
            expectation: entitlementsURL.lastPathComponent)
        let problems = EntitlementPolicy.problems(in: effective, isRelease: isRelease)
        guard problems.isEmpty else {
            Output.err("entitlement policy FAILED:")
            for problem in problems {
                Output.err("  - \(problem)")
            }
            throw ToolError("the signed entitlements break the policy in EntitlementPolicy.swift")
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
        let result = try await ProcessRunner.run(
            CommandSpec(executable: "/usr/bin/codesign", arguments: ["-dv", "--verbose=4", appURL.path]))
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
        let architectures = try await ProcessRunner.run(
            CommandSpec(executable: "/usr/bin/lipo", arguments: ["-archs", executableURL.path]))
        Output.out("architecture:   \(architectures.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        if options.hardened {
            Output.out("profile:        hardened (Enhanced Security entitlements)")
        }
        Output.out("Built \(appURL.path)")
    }
}
