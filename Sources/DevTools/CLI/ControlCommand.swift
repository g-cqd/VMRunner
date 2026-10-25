import AgentBridge
import ArgumentParser
import ControlProtocol
import Foundation

struct ControlCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "control",
        abstract: "Call the local control service of a running VMRunner app, or serve it to an AI agent over MCP.",
        discussion: """
            The app serves its control service on a private local socket once it is turned on in Settings (Automation): \
            Control/control.sock in the app's data folder, which is $VMRUNNER_DATA_DIR when that is set; --socket names \
            another. A call presents a control token made in Settings, read from --token-file FILE (a file only you can read: \
            chmod 600) or from $VMR_CONTROL_TOKEN; never from an argument, which every user can see with ps. --json prints \
            the service's answer as JSON.

            Exit status: 0 done; 1 the service refused the call (no such machine, agent access off, refused); 64 a usage \
            error, no token, or a token that is not one; 66 the token file cannot be read; 69 nothing serves the socket (the \
            service is off or the app is not running); 73 a screenshot cannot be written to its file; 75 no answer in time, and \
            what the call started may still finish; 76 an answer this client cannot read; 77 not permitted (the token lacks the \
            capability, the token file is open to other users, or another user serves the socket).
            """,
        subcommands: [Status.self, List.self, State.self, Start.self, Stop.self, Log.self, Screenshot.self, MCP.self]
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

        /// The token; none is a usage error.
        func requiredToken() throws -> String {
            try ControlTarget.requiredToken(
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

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the machines whose agent access is on: id, state, guest and name.",
            discussion: "Needs a token with the list capability."
        )

        @OptionGroup var target: TargetOptions

        @Flag(help: "Print the service's answer as JSON.")
        var json = false

        func run() async throws {
            try await perform {
                let invocation = try ControlInvocation(target: target)
                if json {
                    Output.out(ControlInvocation.text(try invocation.result(.list, json: true)))
                } else {
                    for line in ControlInvocation.lines(listing: try invocation.machines(json: false)) { Output.out(line) }
                }
                return 0
            }
        }
    }

    /// `--socket`, `--token-file`, the machine and `--json`: what the subcommands that act on one machine share.
    struct MachineOptions: ParsableArguments {
        @OptionGroup var target: TargetOptions

        @Argument(help: ArgumentHelp("The machine: its id, or its name.", valueName: "machine"))
        var machine: String

        @Flag(help: "Print the service's answer as JSON.")
        var json = false

        /// Calls `method` on the machine, with `params` besides the machine, and prints the answer: the service's JSON with
        /// `--json`, otherwise what `describe` makes of it.
        func call(_ method: ControlMethod, params: [String: RPCValue] = [:], describe: (Data) throws -> String) async throws {
            try await perform {
                let invocation = try ControlInvocation(target: target)
                let id = try invocation.machineID(machine, json: json)
                let data = try invocation.result(method, params: params.merging(["machine": .string(id)]) { $1 }, json: json)
                let text = json ? ControlInvocation.text(data) : try describe(data)
                if !text.isEmpty { Output.out(text) }
                return 0
            }
        }
    }

    struct State: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print one machine's state.",
            discussion: "Needs a token with the state capability; naming the machine by its name also needs the list capability."
        )

        @OptionGroup var options: MachineOptions

        func run() async throws {
            try await options.call(.state) { data in
                let found = try ControlInvocation.decode(ControlMachine.self, from: data)
                return "\(found.name) (\(found.id.uuidString)): \(found.state.rawValue)"
            }
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start a machine and wait until it runs or the start fails.",
            discussion: """
                Needs a token with the start capability; naming the machine by its name also needs the list capability. A start \
                the app would ask about (a host folder not yet approved) is refused, never asked. The service answers within \
                120 seconds; past that it says the start timed out (exit 75) and the start goes on.
                """
        )

        @OptionGroup var options: MachineOptions

        func run() async throws {
            try await options.call(.start, describe: ControlInvocation.stateLine)
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ask a machine's guest to shut down, or with --force cut its power.",
            discussion: """
                Needs a token with the stop capability; naming the machine by its name also needs the list capability. Without \
                --force the service answers at once (shuttingDown) and the guest shuts down by itself; with --force it answers \
                once the machine is stopped.
                """
        )

        @OptionGroup var options: MachineOptions

        @Flag(help: "Cut the power at once instead of asking the guest to shut down.")
        var force = false

        func run() async throws {
            try await options.call(.stop, params: ["force": .bool(force)], describe: ControlInvocation.stateLine)
        }
    }

    struct Log: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the end of a container machine's output log.",
            discussion: """
                Needs a token with the log capability; naming the machine by its name also needs the list capability. Only a \
                container machine keeps a log: a virtual machine is refused (exit 1). The service answers with the last 64 KiB \
                at most; --bytes asks for fewer. When the log held more than what is printed, a first line says \
                [earlier output not shown].
                """
        )

        @OptionGroup var options: MachineOptions

        @Option(name: .long, help: ArgumentHelp("How many bytes of the end of the log to print (1 to 65536).", valueName: "n"))
        var bytes = ControlLog.maxBytes

        func validate() throws {
            guard (1...ControlLog.maxBytes).contains(bytes) else {
                throw ValidationError("--bytes must be between 1 and \(ControlLog.maxBytes)")
            }
            guard !options.json || bytes == ControlLog.maxBytes else {
                throw ValidationError("--bytes does not apply to --json, which prints the service's answer")
            }
        }

        func run() async throws {
            try await options.call(.log) { data in
                let log = try ControlInvocation.decode(ControlLog.self, from: data)
                let end = ControlLog.end(of: log.text, bytes: bytes)
                let notice = log.truncated || end.cut ? "[earlier output not shown]\n" : ""
                // The text ends with its own newline, and printing adds one.
                return notice + (end.text.hasSuffix("\n") ? String(end.text.dropLast()) : end.text)
            }
        }
    }

    struct Screenshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save a PNG of a running machine's screen to a file.",
            discussion: """
                Needs a token with the screen capability; naming the machine by its name also needs the list capability. Only a \
                machine that uses the custom GPU has a screen to read. The picture is at most 1280 pixels on its longest side. \
                The file is written for you only. With --json the service's answer is printed instead, the picture in it as \
                base64, and no file is written.
                """
        )

        @OptionGroup var options: MachineOptions

        @Option(name: .shortAndLong, help: ArgumentHelp("The file to write the PNG to.", valueName: "file"))
        var output: String?

        func validate() throws {
            if options.json == (output != nil) {
                throw ValidationError("give --output FILE to save the picture, or --json to print the answer, not both")
            }
        }

        func run() async throws {
            let output = output ?? ""
            try await options.call(.screenshot) { data in try ControlInvocation.save(screenshot: data, to: output) }
        }
    }

    struct MCP: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mcp",
            abstract: "Serve the control service to an AI agent: an MCP server over standard input and output.",
            discussion: """
                Give an agent's MCP configuration the built vmr binary with the arguments `control mcp`, and the token in \
                VMR_CONTROL_TOKEN (or --token-file). It speaks the Model Context Protocol (2025-11-25, and 2025-06-18) as one \
                JSON-RPC message per line and offers six tools, machines_list, machines_state, machines_start, machines_stop, \
                machines_log and machines_screenshot: each one call of the control service with the token, so the service's \
                checks decide what the agent may do. Only answers are written to standard output; it ends with its input. The \
                service may be off when it starts: a tool call then answers that the service could not be used.
                """
        )

        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await perform {
                let caller = ControlCaller(token: try target.requiredToken(), socket: try target.socketPath())
                return MCPStdio.serve(input: STDIN_FILENO, output: STDOUT_FILENO, caller: caller)
            }
        }
    }
}
