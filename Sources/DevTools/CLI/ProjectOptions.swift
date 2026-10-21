import ArgumentParser
import Foundation

/// `--root`, shared by every command that works on a checkout.
struct ProjectOptions: ParsableArguments {
    @Option(
        name: .long, help: ArgumentHelp("The package directory (default: the nearest directory with a Package.swift).", valueName: "dir"))
    var root: String?

    /// The package root: `--root`, or the nearest directory at or above the current one that holds a `Package.swift`.
    func packageRoot() throws -> URL {
        let current = Self.currentDirectory
        if let root {
            return URL(fileURLWithPath: root, relativeTo: current).standardizedFileURL
        }
        var candidate = current.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: candidate.appending(path: "Package.swift").path) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        throw ToolError.usage("no Package.swift at or above \(current.path); run inside the package or pass --root DIR")
    }

    /// `--root`, or the current directory: where a git command starts looking for the repository.
    func workingDirectory() -> URL {
        let current = Self.currentDirectory
        return root.map { URL(fileURLWithPath: $0, relativeTo: current).standardizedFileURL } ?? current
    }

    private static var currentDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}

/// Runs a command body: a `ToolError` is reported as `error: <message>` on stderr, and a non-zero status becomes the
/// exit status of the process.
func perform(_ body: () async throws -> Int32) async throws {
    do {
        let status = try await body()
        if status != 0 { throw ExitCode(status) }
    } catch let error as ToolError {
        Output.err("error: \(error.message)")
        throw ExitCode(error.status)
    }
}
