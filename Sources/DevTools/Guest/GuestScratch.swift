import Foundation
import VMHelperCore

/// The scratch directory a guest run lives in: what was fetched, and the private directory of the running helper.
///
///     DIR/download/   the vendor's files as downloaded, and the signature check's keyring
///     DIR/netboot/    the files a guest boots from
///     DIR/guest/      0700: the descriptor, the console socket, the helper's pid file and log
///
/// Everything a `vmr guest` command writes is under `DIR`, and `DIR` is never the owner's library.
struct GuestScratch: Equatable {
    let root: URL

    var downloadDirectory: URL { root.appending(path: "download", directoryHint: .isDirectory) }
    var netbootDirectory: URL { root.appending(path: "netboot", directoryHint: .isDirectory) }
    var runDirectory: URL { root.appending(path: "guest", directoryHint: .isDirectory) }
    var descriptorFile: URL { runDirectory.appending(path: "descriptor.json") }
    var socket: URL { runDirectory.appending(path: "console.sock") }
    var pidFile: URL { runDirectory.appending(path: "helper.pid") }
    var logFile: URL { runDirectory.appending(path: "helper.log") }
    /// The network policy a filtered guest enforces (the descriptor names it), and the named pipe its helper reads commands from.
    var policyFile: URL { runDirectory.appending(path: "policy.json") }
    var commandPipe: URL { runDirectory.appending(path: "commands.fifo") }

    /// The directory `path` names (relative to `workingDirectory`). Refuses the root of the disk, the home folder and
    /// anything inside the user's `Library`, where the app keeps its machines, whatever links lead there.
    init(path: String, workingDirectory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard !path.isEmpty else { throw ToolError.usage("the scratch directory is empty; pass --directory DIR") }
        let requested = URL(fileURLWithPath: path, relativeTo: workingDirectory).standardizedFileURL
        let real = Self.realPath(of: requested)
        let forbidden = [("the root of the disk", "/"), ("your home folder", home.path)]
        for (name, candidate) in forbidden where real == Self.realPath(of: URL(fileURLWithPath: candidate)) {
            throw ToolError("\(requested.path) is \(name); give a scratch directory of its own")
        }
        let library = Self.realPath(of: home.appending(path: "Library", directoryHint: .isDirectory))
        if real == library || real.hasPrefix(library + "/") {
            throw ToolError(
                "\(requested.path) is inside your Library, where the app keeps its machines; give a scratch directory under /tmp")
        }
        root = requested
    }

    /// The real path of `url`, resolving links through the deepest part that exists.
    private static func realPath(of url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while SandboxPath.realPath(existing.path) == nil, existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        let base = SandboxPath.realPath(existing.path) ?? existing.path
        return rest.isEmpty ? base : (base == "/" ? "" : base) + "/" + rest.joined(separator: "/")
    }

    /// Creates `directory` with mode 0700 when it is missing; an existing one must already be private to the user.
    static func ensurePrivate(_ directory: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        let mode = (attributes[.posixPermissions] as? Int) ?? 0o777
        guard mode & 0o077 == 0 else {
            throw ToolError("\(directory.path) is open to other users (mode \(String(mode, radix: 8))); run chmod 700 on it")
        }
    }
}
