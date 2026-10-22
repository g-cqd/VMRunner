import ArgumentParser
import Foundation
import GuestConsole
import VMHelperCore

struct GuestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guest",
        abstract: "Run a small Linux guest in a scratch directory and act on it through its console.",
        discussion: """
            The real-guest runs of CONTRIBUTING.md and the first piece of the automation server (roadmap 0005): `fetch` downloads \
            Alpine's netboot image, `start` boots it with 2 CPUs and 2 GiB at most behind a console socket, `exec` and `console` \
            act on the guest through that socket, and `stop` ends it. Everything is under the --directory you give, which is \
            never your Library. `start` boots a virtual machine: agents run it only when the owner has authorised real-guest \
            runs for the session.
            """,
        subcommands: [Fetch.self, Start.self, Exec.self, Console.self, Policy.self, Flows.self, Stop.self]
    )

    /// `--directory`, shared by the commands that work on a scratch directory.
    struct DirectoryOptions: ParsableArguments {
        @Option(name: .long, help: ArgumentHelp("The scratch directory (never inside your Library).", valueName: "dir"))
        var directory: String

        func scratch() throws -> GuestScratch {
            try GuestScratch(path: directory, workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }
    }

    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download a guest image into an empty scratch directory.",
            subcommands: [AlpineNetbootCommand.self]
        )
    }

    struct AlpineNetbootCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "alpine-netboot",
            abstract: "Download, check and unpack the newest signed Alpine aarch64 netboot image.",
            discussion: """
                From https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/ over https: the newest release that \
                has a .asc signature, checked against its .sha256 and, when gpg is installed, against Alpine's release key \
                (fetched from alpinelinux.org and accepted only with the fingerprint \(AlpineNetboot.keyFingerprint)). The \
                archive is listed before it is unpacked and refused if it holds anything but plain files inside the target. \
                Yields netboot/vmlinuz-virt, netboot/Image-virt (the kernel the framework boots), netboot/initramfs-virt and \
                netboot/modloop-virt. The directory must be new or empty.
                """
        )

        @OptionGroup var target: DirectoryOptions

        func run() async throws {
            try await perform {
                _ = try await NetbootFetch(scratch: target.scratch()).run()
                return 0
            }
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "START A VIRTUAL MACHINE from the fetched image and wait for its console prompt.",
            discussion: """
                Writes a descriptor (kernel, initramfs, NAT, a console socket), builds and signs the headless helper, starts it \
                detached with a pid file and a log under DIR/guest, and waits until the console shows a prompt. The helper stops \
                the machine after --max-seconds whatever happens. Only the repository owner, or an agent the owner has \
                authorised for the session, runs this.
                """
        )

        @OptionGroup var project: ProjectOptions
        @OptionGroup var target: DirectoryOptions

        @Option(name: .long, help: ArgumentHelp("Processors for the guest (1 or 2).", valueName: "n"))
        var cpus = 2

        @Option(name: .long, help: ArgumentHelp("Memory for the guest in MiB (512 to 2048).", valueName: "mib"))
        var memoryMib = 2_048

        @Option(name: .long, help: ArgumentHelp("Hard limit on the machine's run time, in seconds.", valueName: "seconds"))
        var maxSeconds = GuestPlan.defaultMaximumSeconds

        @Option(name: .long, help: ArgumentHelp("How long to wait for the machine and its prompt, in seconds.", valueName: "seconds"))
        var bootTimeout = 180

        @Option(
            name: .long,
            help: ArgumentHelp("The kernel command line (default: console=hvc0 ip=dhcp and the release's repository).", valueName: "line"))
        var commandLine: String?

        @Option(
            name: .long, help: ArgumentHelp("The helper's build configuration: debug or release.", valueName: "configuration"),
            transform: { text in
                guard let value = AppBundler.Configuration(rawValue: text) else {
                    throw ValidationError("'\(text)' is not debug or release")
                }
                return value
            })
        var configuration = AppBundler.Configuration.release

        @Option(name: .long, help: ArgumentHelp("A helper binary built already, signed here instead of building one.", valueName: "path"))
        var helper: String?

        @Option(
            name: .long,
            help: ArgumentHelp(
                "The guest's network: nat (the framework's) or filtered (the app's, judged by a policy).", valueName: "mode"),
            transform: { text in
                guard let value = HelperDescriptor.Network(rawValue: text), value == .nat || value == .filtered else {
                    throw ValidationError("'\(text)' is not nat or filtered")
                }
                return value
            })
        var net = HelperDescriptor.Network.nat

        @Option(
            name: .long,
            help: ArgumentHelp("With --net filtered: the network policy as JSON (default: the default policy).", valueName: "file"))
        var policy: String?

        @Option(
            name: .long, help: ArgumentHelp("With --net filtered: what a denied TCP connection sees: reset or drop.", valueName: "action"),
            transform: { text in
                guard let value = HelperDescriptor.DenyAction(rawValue: text) else {
                    throw ValidationError("'\(text)' is not reset or drop")
                }
                return value
            })
        var denyAction = HelperDescriptor.DenyAction.reset

        func run() async throws {
            try await perform {
                var plan = GuestPlan(cpuCount: cpus, memoryMiB: memoryMib, commandLine: commandLine)
                plan.network = net
                plan.denyAction = denyAction
                plan.policyFile = policy.map { URL(fileURLWithPath: $0, relativeTo: project.workingDirectory()).standardizedFileURL }
                var start = GuestStart(scratch: try target.scratch(), plan: plan, root: try project.packageRoot())
                start.configuration = configuration
                start.prebuilt = helper.map { URL(fileURLWithPath: $0, relativeTo: project.workingDirectory()).standardizedFileURL }
                start.maximumSeconds = maxSeconds
                start.bootTimeout = .seconds(bootTimeout)
                return try await start.run()
            }
        }
    }

    struct Exec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run one command in the guest through its console; print its output and exit with its status.",
            discussion: """
                Logs in as root if the console shows a login prompt, types `echo START; command; echo END_$?` and reads the output \
                back between the markers. Exits with the command's status; 124 when it ran out of time, 125 when the console \
                could not be used (nothing serving it, another client attached, closed). The command is one line.
                """
        )

        @Argument(help: ArgumentHelp("The console socket `vmr guest start` printed.", valueName: "socket"))
        var socket: String

        @Option(name: .long, help: ArgumentHelp("The user to log in as if the console asks.", valueName: "user"))
        var user = "root"

        @Option(name: .long, help: ArgumentHelp("Seconds the command may take.", valueName: "seconds"))
        var timeout = 60

        @Argument(parsing: .postTerminator, help: ArgumentHelp("The command, after `--`.", valueName: "command"))
        var command: [String] = []

        func validate() throws {
            guard !command.isEmpty else { throw ValidationError("give the command after `--`") }
            guard timeout > 0 else { throw ValidationError("--timeout must be positive") }
        }

        func run() async throws {
            try await perform {
                let result = try await GuestExec(
                    socket: socket, command: command.joined(separator: " "), user: user, timeout: .seconds(timeout)
                )
                .run()
                try FileHandle.standardOutput.write(contentsOf: Data(result.output.utf8))
                return result.status
            }
        }
    }

    struct Console: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Attach this terminal to the guest's console (Ctrl-] detaches).",
            discussion: """
                Raw passthrough: every key goes to the guest, everything the guest prints comes back, nothing is interpreted \
                here. The console takes one client at a time.
                """
        )

        @Argument(help: ArgumentHelp("The console socket `vmr guest start` printed.", valueName: "socket"))
        var socket: String

        func run() async throws {
            try await perform {
                Output.err("attached to \(socket); Ctrl-] detaches")
                let ending: ConsoleRelay.Ending
                do {
                    ending = try TerminalMode.raw {
                        try ConsoleRelay.run(socketPath: socket, input: STDIN_FILENO, output: STDOUT_FILENO)
                    }
                } catch let error as ConsoleError {
                    throw GuestExec.failure(error)
                }
                switch ending {
                case .consoleClosed: Output.err("\nthe console closed")
                case .inputEnded: Output.err("\nend of input")
                case .detached: Output.err("\ndetached")
                }
                return 0
            }
        }
    }

    /// How a command names the guest it means: a console socket, a helper's pid, or the scratch directory.
    struct GuestArgument: ParsableArguments {
        @Argument(help: ArgumentHelp("The guest: its console socket, its helper's pid, or its scratch directory.", valueName: "guest"))
        var guest: String

        func scratch() async throws -> GuestScratch {
            try await GuestTarget.scratch(
                for: guest, workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }
    }

    struct Policy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Give a running guest with a filtered network a new policy, without restarting it.",
            discussion: """
                Replaces the policy file the guest's helper reads, tells the helper to read it again and waits for its answer. \
                Flows the new policy no longer allows are cut unless --keep-open-flows is given. Exits 1 when the helper rejected \
                the file or did not answer in time.
                """
        )

        @OptionGroup var target: GuestArgument

        @Argument(help: ArgumentHelp("The policy as JSON.", valueName: "file"))
        var file: String

        @Flag(help: "Leave open flows alone even when the new policy would not allow them.")
        var keepOpenFlows = false

        @Option(name: .long, help: ArgumentHelp("Seconds to wait for the helper's answer.", valueName: "seconds"))
        var timeout = 10

        func run() async throws {
            try await perform {
                var update = GuestPolicy(
                    scratch: try await target.scratch(),
                    file: URL(fileURLWithPath: file, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                        .standardizedFileURL)
                update.terminatingOpenFlows = !keepOpenFlows
                update.timeout = .seconds(timeout)
                let answer = try await update.run()
                Output.out("\(answer.applied ? "applied" : "rejected"): \(answer.message)")
                return answer.applied ? 0 : 1
            }
        }
    }

    struct Flows: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print what a filtered guest's connections did: the helper's flow events and its counters.",
            discussion: """
                Reads the helper's log. A line is the transport, the outcome (allowed, denied, answered, closed, revoked), the \
                destination and the reason; the time is seconds since the helper started.
                """
        )

        @OptionGroup var target: GuestArgument

        @Option(name: .long, help: ArgumentHelp("How many of the newest lines to print.", valueName: "n"))
        var last = 50

        @Option(name: .long, help: ArgumentHelp("Only lines with this outcome.", valueName: "outcome"))
        var only: String?

        func run() async throws {
            try await perform {
                var flows = GuestFlows(scratch: try await target.scratch())
                flows.last = last
                flows.outcome = only
                for line in try flows.lines() { Output.out(line) }
                return 0
            }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop the guest started from a scratch directory and remove its socket.",
            discussion:
                "SIGTERM to the recorded helper, SIGKILL after five seconds; only a process still running what was recorded."
        )

        @OptionGroup var target: DirectoryOptions

        func run() async throws {
            try await perform {
                try await GuestStop(scratch: target.scratch()).run()
                return 0
            }
        }
    }
}
