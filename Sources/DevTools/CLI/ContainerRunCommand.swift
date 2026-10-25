import ArgumentParser
import Foundation

extension ContainerRunPlan.Network: ExpressibleByArgument {}

struct ContainerRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-run",
        abstract: "BOOT A VIRTUAL MACHINE: build, sign and run the container runner on an image and a command.",
        discussion: """
            Builds and signs the runner exactly as `vmr container-sign` does (--binary skips the build), makes a scratch \
            directory (a new private one under the temporary directory, printed; --scratch reuses one, so the kernel and the \
            image store survive between runs), runs the signed runner there with the options below, streams its standard output \
            and error through, and exits with its status. The runner pulls the image, boots a Linux virtual machine and runs \
            the command in it.

            This boots a real virtual machine. CONTRIBUTING.md ("Real-guest runs") says: "Run it only when the owner has \
            authorised real-guest runs for the session", with the guest's resources capped, so the command refuses to run \
            without --boot (as `vmr sandbox run` does), takes at most \(ContainerRunPlan.maximumCPUs) CPUs and \
            \(ContainerRunPlan.maximumMemoryMiB) MiB, and stops the runner after --max-seconds (status 124). Delete the \
            scratch directory when you are done. Tests and agents without that authorisation never run it.

            With --json the runner prints one JSON event per line on standard output and reads standard input: a `stop` line or \
            its end stops the container (status 75). The runner's own options are described by `ContainerRunner --help`. The \
            build's progress goes to standard output, so pass --binary for an event stream with nothing else on it. SIGINT and \
            SIGTERM stop the runner before this command exits, with status 128 plus the signal's number.
            """
    )

    @OptionGroup var project: ProjectOptions

    @Flag(help: "Confirm that this boots a real virtual machine and that the owner has authorised real-guest runs.")
    var boot = false

    @Argument(help: "The build configuration, debug or release (default: release).")
    var configuration: AppBundler.Configuration?

    @Option(name: .long, help: ArgumentHelp("Run this executable, signed here, instead of building one.", valueName: "path"))
    var binary: String?

    @Option(name: .long, help: ArgumentHelp("Use this directory (new, or private to you) so its caches survive.", valueName: "dir"))
    var scratch: String?

    @Option(name: .long, help: ArgumentHelp("The image to run (the runner's default is alpine).", valueName: "reference"))
    var image: String?

    @Option(
        name: .long, parsing: .unconditionalSingleValue,
        help: ArgumentHelp("One argument of the command; repeat it for each, no shell.", valueName: "argument"))
    var command: [String] = []

    @Option(name: .long, help: ArgumentHelp("Virtual processors, 1 to \(ContainerRunPlan.maximumCPUs).", valueName: "n"))
    var cpus: Int?

    @Option(name: .long, help: ArgumentHelp("Memory in MiB, up to \(ContainerRunPlan.maximumMemoryMiB).", valueName: "mib"))
    var memory: Int?

    @Option(name: .long, help: ArgumentHelp("An environment variable for the command; repeat it, once per name.", valueName: "NAME=value"))
    var env: [String] = []

    @Option(name: .long, help: ArgumentHelp("none or loopback (the runner's default is none).", valueName: "mode"))
    var network: ContainerRunPlan.Network?

    @Flag(help: "Print one JSON event per line on standard output; a `stop` line on standard input stops the container.")
    var json = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Seconds after which the runner is stopped (1 to \(ContainerRunPlan.maximumSecondsLimit)).", valueName: "seconds"))
    var maxSeconds = ContainerRunPlan.defaultMaximumSeconds

    func run() async throws {
        try await perform {
            var options = ContainerRunPlan.Options()
            options.confirmed = boot
            options.scratch = scratch
            options.image = image
            options.command = command
            options.cpus = cpus
            options.memoryMiB = memory
            options.environment = env
            options.network = network
            options.json = json
            options.maximumSeconds = maxSeconds
            let plan = try ContainerRunPlan.make(options, in: .current())
            return try await ContainerRun(
                root: try project.packageRoot(),
                binary: binary.map { URL(fileURLWithPath: $0) },
                configuration: configuration ?? .release,
                plan: plan
            ).run()
        }
    }
}
