import Foundation

/// The `swift build` and `codesign` steps that every bundler shares: build and find the products, sign, verify the
/// signature, read the effective entitlements back and compare them with what was asked for.
enum BuildTools {
    /// Runs `swift build <arguments>` with its output inherited, then asks it where the products went.
    static func build(_ arguments: [String]) async throws -> URL {
        let build = try await ProcessRunner.run(
            CommandSpec(executable: "swift", arguments: ["build", GateSteps.resolvedOnly] + arguments), output: .inherit)
        guard build.succeeded else { throw ToolError("swift build failed", status: build.status) }

        let path = try await ProcessRunner.run(
            CommandSpec(executable: "swift", arguments: ["build", GateSteps.resolvedOnly] + arguments + ["--show-bin-path"]))
        guard path.succeeded, let line = path.standardOutput.split(whereSeparator: \.isNewline).last else {
            throw ToolError("swift build --show-bin-path failed: \(path.standardError)")
        }
        return URL(fileURLWithPath: String(line))
    }

    /// Copies `binary` and `infoPlist` into a fresh bundle at `bundle`, which is `Contents/MacOS/<executable>` and
    /// `Contents/Info.plist`.
    static func assemble(bundle: URL, executable: String, binary: URL, infoPlist: URL) throws {
        let fileManager = FileManager.default
        let executableURL = bundle.appending(path: "Contents/MacOS/\(executable)")
        try? fileManager.removeItem(at: bundle)
        try fileManager.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: binary, to: executableURL)
        guard fileManager.fileExists(atPath: infoPlist.path) else { throw ToolError("cannot read \(infoPlist.path)") }
        try fileManager.copyItem(at: infoPlist, to: bundle.appending(path: "Contents/Info.plist"))
    }

    static func codesign(_ arguments: [String]) async throws {
        let result = try await ProcessRunner.run(CommandSpec(executable: "/usr/bin/codesign", arguments: arguments), output: .inherit)
        guard result.succeeded else { throw ToolError("codesign \(arguments[0]) failed", status: result.status) }
    }

    static func verifySignature(of url: URL) async throws {
        try await codesign(["--verify", "--strict", "--deep", "--verbose=1", url.path])
    }

    /// The effective entitlements, read back from the signed code at `url`, must equal `expected`; a mismatch is listed on
    /// standard error and fails with a message that names `expectation`. Returns the effective entitlements.
    static func verifyEntitlements(
        of url: URL, expected: Entitlements.Dictionary, isRelease: Bool, expectation: String
    ) async throws -> Entitlements.Dictionary {
        let result = try await ProcessRunner.run(
            CommandSpec(executable: "/usr/bin/codesign", arguments: ["-d", "--entitlements", ":-", url.path]))
        guard result.succeeded else { throw ToolError("codesign could not read the entitlements: \(result.standardError)") }
        let effective = try Entitlements.parse(Data(result.standardOutput.utf8))
        let problems = Entitlements.problems(effective: effective, expected: expected, isRelease: isRelease)
        guard problems.isEmpty else {
            Output.err("entitlement check FAILED:")
            for problem in problems {
                Output.err("  - \(problem)")
            }
            throw ToolError("the signed entitlements differ from \(expectation)")
        }
        return effective
    }
}
