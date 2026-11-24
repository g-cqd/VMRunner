import ArgumentParser
import Foundation

struct WindowsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "Helpers for Windows machines.",
        subcommands: [Drivers.self, WindowsFirmwareCommand.self]
    )

    struct Drivers: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "drivers",
            abstract: "Driver discs for a Windows machine.",
            subcommands: [Verify.self]
        )

        struct Verify: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "verify",
                abstract: "Checks a driver disc you downloaded against the SHA-256 values pinned in this repository.",
                discussion: """
                    Hashes FILE (read-only, in chunks) and looks its SHA-256 up in \(DriverPins.relativePath) under the package root. \
                    It prints the matching entry, or "not in the pinned list" with the value it computed. It downloads nothing, \
                    uses no network and changes no file.

                    The list ships empty: which discs to trust is the owner's decision. The owner adds an entry (sha256, name, \
                    version, notes with the source and the date of the file they checked) to that file; a SHA-256 comes from \
                    `shasum -a 256 FILE`.

                    Exit status: 0 the file matches an entry; 1 it is not in the pinned list; 64 a usage error; 65 the pinned list \
                    cannot be read or is malformed; 66 FILE cannot be read, is a directory, or is not a regular file.
                    """
            )

            @OptionGroup var project: ProjectOptions

            @Argument(help: ArgumentHelp("The driver disc image to check.", valueName: "file"))
            var file: String

            func run() async throws {
                try await perform {
                    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    let pins = try DriverPins.load(from: try project.packageRoot().appending(path: DriverPins.relativePath))
                    let digest = try FileDigest.sha256(ofFileAt: URL(fileURLWithPath: file, relativeTo: cwd).standardizedFileURL)
                    guard let entry = pins.entry(forDigest: digest) else {
                        Output.out("not in the pinned list")
                        Output.out("sha256: \(digest)")
                        return DriverVerifyStatus.noMatch
                    }
                    Output.out("matches the pinned entry: \(entry.name) \(entry.version)")
                    Output.out("sha256: \(digest)")
                    Output.out("notes: \(entry.notes)")
                    return 0
                }
            }
        }
    }
}
