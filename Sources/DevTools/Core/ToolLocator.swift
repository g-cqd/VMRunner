import Foundation

/// Finds programs the way a shell would, without running one.
enum ToolLocator {
    static func resolve(_ name: String, searchPath: String?) throws -> URL {
        let fileManager = FileManager.default
        if name.contains("/") {
            guard fileManager.isExecutableFile(atPath: name) else { throw ToolError("\(name) is not an executable") }
            return URL(fileURLWithPath: name)
        }
        for directory in (searchPath ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appending(path: name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw ToolError("'\(name)' not found in PATH")
    }

    /// swift-format from `PATH`, or the one in the active Xcode toolchain (`xcrun --find`) when `PATH` has none.
    static func swiftFormat(environment: [String: String]) async throws -> String {
        if let found = try? resolve("swift-format", searchPath: environment["PATH"]) {
            return found.path
        }
        let spec = CommandSpec(executable: "xcrun", arguments: ["--find", "swift-format"], environment: environment)
        let result = try await ProcessRunner.run(spec)
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !path.isEmpty else { throw ToolError("'swift-format' not found in PATH or in the active toolchain") }
        return path
    }

    /// A `<TOOL>_BIN` override is run without the pin's checksum or version check. On CI (the `CI` variable is set) that
    /// is a supply-chain hole a workflow change can open, so say so loudly on standard error.
    static func noteOverride(variable: String, path: String, environment: [String: String]) {
        guard let ci = environment["CI"], !ci.isEmpty else { return }
        Output.err(
            "WARNING: CI is set and \(variable)=\(path) replaces the pinned, checksum-verified release: "
                + "that binary is run without any check")
    }

    /// `SWIFTLINT_BIN` when set, otherwise the SwiftLint release pinned in `Scripts/analyzers.lock`, downloaded and
    /// verified on first use (never taken from `PATH`, so every checkout lints with the same version).
    static func swiftlint(root: URL, environment: [String: String]) async throws -> String {
        if let override = environment[ReleaseSpec.swiftlint.binaryOverrideVariable], !override.isEmpty {
            noteOverride(variable: ReleaseSpec.swiftlint.binaryOverrideVariable, path: override, environment: environment)
            return try resolve(override, searchPath: environment["PATH"]).path
        }
        let pin = try AnalyzerLock.load(root: root).pin(for: .swiftlint)
        let installer = try AnalyzerInstaller(root: root, environment: environment)
        return try await installer.install(pin).path
    }
}
