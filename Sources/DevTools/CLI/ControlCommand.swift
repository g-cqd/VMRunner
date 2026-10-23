import ArgumentParser
import ControlProtocol
import Foundation

struct ControlCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "control",
        abstract: "Call the local control service of a running VMRunner app.",
        discussion: """
            The app serves its control service on a private local socket once it is turned on in Settings (Automation): \
            Control/control.sock in the app's data folder, which is $VMRUNNER_DATA_DIR when that is set; --socket names \
            another. A call presents a control token made in Settings, read from --token-file FILE (a file only you can read: \
            chmod 600) or from $VMR_CONTROL_TOKEN; never from an argument, which every user can see with ps. --json prints \
            the service's answer as JSON.

            Exit status: 0 done; 1 the service refused the call (no such machine, agent access off, refused); 64 a usage \
            error, no token, or a token that is not one; 66 the token file cannot be read; 69 nothing serves the socket (the \
            service is off or the app is not running); 75 no answer in time, and what the call started may still finish; 76 \
            an answer this client cannot read; 77 not permitted (the token lacks the capability, the token file is open to \
            other users, or another user serves the socket).
            """,
        subcommands: [Status.self]
    )

    /// `--socket` and `--token-file`, shared by every subcommand.
    struct TargetOptions: ParsableArguments {
        @Option(
            name: .long, help: ArgumentHelp("The control socket (default: Control/control.sock in the data folder).", valueName: "path"))
        var socket: String?

        @Option(
            name: .long,
            help: ArgumentHelp("A file holding the token, readable by you only (default: $VMR_CONTROL_TOKEN).", valueName: "file"))
        var tokenFile: String?

        func socketPath() throws -> String {
            try ControlTarget.socketPath(
                socket, environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser,
                currentDirectory: Self.currentDirectory)
        }

        /// The token, or nil when none is given.
        func token() throws -> String? {
            try ControlTarget.token(
                file: tokenFile, environment: ProcessInfo.processInfo.environment, currentDirectory: Self.currentDirectory)
        }

        private static var currentDirectory: URL {
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Say whether the control service answers and, with a token, whether it is accepted.",
            discussion: """
                Looks for the socket and connects to it; when a token is given (it is optional here), lists the machines with \
                it. Exits 0 when the service answers and the token, if any, is accepted; 69 when nothing serves the socket; 77 \
                when the token is refused.
                """
        )

        @OptionGroup var target: TargetOptions

        @Flag(help: "Print the result as one JSON object.")
        var json = false

        func run() async throws {
            try await perform {
                // The token is read first: a token file open to other users is refused before anything is sent.
                let token = try target.token()
                let status = ControlStatus.check(socket: try target.socketPath(), token: token)
                if json {
                    Output.out(status.json)
                } else {
                    for line in status.lines { Output.out(line) }
                }
                if let failure = status.failure { throw failure }
                return status.exitStatus
            }
        }
    }
}
