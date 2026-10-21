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
}
