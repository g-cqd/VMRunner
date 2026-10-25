import Foundation

/// The command line of the container runner for one container machine. The runner checks every value again; the spec was
/// checked by `VMConfig.validate()`, so a line built here is one it accepts.
enum ContainerRunnerArguments {
    /// `<scratch> --json --image <reference> --cpus <n> --memory <MiB> --network <none|loopback>`, then one `--env NAME=value`
    /// per environment entry in the spec's order and one `--command <element>` per command element. The command is not run
    /// through a shell, and an element that starts with a dash is still one value of `--command`.
    static func make(for spec: ContainerSpec, scratch: URL) -> [String] {
        var arguments = [
            scratch.path, "--json", "--image", spec.image, "--cpus", String(spec.cpus), "--memory", String(spec.memoryMiB),
            "--network", spec.network.rawValue,
        ]
        for entry in spec.environment {
            arguments += ["--env", "\(entry.name)=\(entry.value)"]
        }
        for element in spec.command {
            arguments += ["--command", element]
        }
        return arguments
    }

    /// What a runner inherits from the app: the search path, the home folder and the temporary folder, and nothing else (no
    /// `DYLD_*` variable, no proxy or credential variable). The container's own environment travels as `--env` arguments.
    static func minimalEnvironment(from source: [String: String]) -> [String: String] {
        var environment = ["PATH": source["PATH"] ?? "/usr/bin:/bin"]
        for name in ["HOME", "TMPDIR"] {
            if let value = source[name] { environment[name] = value }
        }
        return environment
    }
}

/// The folder a runner works in: it holds the kernel and the image cache it downloads, so it outlives a run and nothing here
/// removes it.
enum ContainerScratch {
    struct Refusal: LocalizedError, Equatable {
        let path: String
        var errorDescription: String? { "The container's working folder \(path) is not a folder of its own (a link or a file)." }
    }

    /// Creates the folder with permissions 0700, with its parents as needed, and makes an existing one 0700. A link or a
    /// file in its place is refused: the runner would write through it.
    static func prepare(_ url: URL) throws {
        let manager = FileManager.default
        if let type = try? manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, type != .typeDirectory {
            throw Refusal(path: url.path)
        }
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
