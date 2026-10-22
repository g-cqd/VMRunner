import Foundation

/// Which running guest a command means, given the way a person has it at hand: its console socket, the pid of its helper, or
/// the scratch directory it was started from.
enum GuestTarget {
    /// The scratch directory of the guest `argument` names.
    ///
    /// - A number is the pid of a helper: its command line names the descriptor, which lives in the run directory.
    /// - A path to a socket (or any file) in a run directory is that run directory's guest.
    /// - A path to a directory is the scratch directory itself, or its `guest` directory.
    static func scratch(
        for argument: String, workingDirectory: URL, commandLine: (Int32) async -> String? = Self.commandLine(ofProcess:)
    ) async throws -> GuestScratch {
        let runDirectory: URL
        if let pid = Int32(argument) {
            guard let line = await commandLine(pid), let descriptor = descriptorPath(inCommandLine: line) else {
                throw ToolError("process \(pid) is not a guest helper started by vmr guest (no --descriptor in its command line)")
            }
            runDirectory = URL(fileURLWithPath: descriptor).deletingLastPathComponent()
        } else {
            let path = URL(fileURLWithPath: argument, relativeTo: workingDirectory).standardizedFileURL
            guard let isDirectory = (try? path.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory else {
                throw ToolError("\(path.path) does not exist; name a console socket, a helper pid or a scratch directory")
            }
            if !isDirectory {
                runDirectory = path.deletingLastPathComponent()
            } else if FileManager.default.fileExists(atPath: path.appending(path: "guest/descriptor.json").path) {
                runDirectory = path.appending(path: "guest", directoryHint: .isDirectory)
            } else {
                runDirectory = path
            }
        }
        guard runDirectory.lastPathComponent == "guest" else {
            throw ToolError("\(runDirectory.path) is not the guest directory of a scratch directory")
        }
        return try GuestScratch(path: runDirectory.deletingLastPathComponent().path, workingDirectory: workingDirectory)
    }

    /// The path after `--descriptor` in a helper's command line.
    static func descriptorPath(inCommandLine line: String) -> String? {
        let words = line.split(separator: " ").map(String.init)
        guard let flag = words.firstIndex(of: "--descriptor"), flag + 1 < words.count else { return nil }
        let path = words[flag + 1]
        return path.hasPrefix("/") ? path : nil
    }

    /// What `ps` shows as the command line of `pid`, or `nil` when there is no such process.
    static func commandLine(ofProcess pid: Int32) async -> String? {
        let spec = CommandSpec(executable: "/bin/ps", arguments: ["-ww", "-o", "command=", "-p", "\(pid)"])
        guard let result = try? await ProcessRunner.run(spec), result.succeeded else { return nil }
        let line = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }
}
