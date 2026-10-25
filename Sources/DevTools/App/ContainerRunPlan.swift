import Foundation

/// What `vmr container-run` was asked to do, checked, and the command line it gives the runner. Pure: it reads no file and
/// starts nothing, so a test covers it without the runner or its package.
///
/// The limits are those of CONTRIBUTING.md's real-guest runs (at most 2 CPUs and 2048 MiB, a hard run-time limit), because
/// running the runner boots a virtual machine. The runner checks the rest of its options itself and refuses what it does not
/// accept before anything starts.
struct ContainerRunPlan: Equatable {
    static let maximumCPUs = 2
    static let maximumMemoryMiB = 2_048
    static let defaultMaximumSeconds = 900
    static let maximumSecondsLimit = 3_600
    /// The runner's own lowest memory size, so that a request below it is refused here, before a build.
    static let minimumMemoryMiB = 128

    /// How the container is attached to a network, as the runner names it.
    enum Network: String, CaseIterable, Equatable {
        case none
        case loopback
    }

    /// The options as typed.
    struct Options: Equatable {
        /// `--boot`: the caller confirms that this boots a real virtual machine.
        var confirmed = false
        /// `--scratch`; nil makes a fresh directory.
        var scratch: String?
        var image: String?
        var command: [String] = []
        var cpus: Int?
        var memoryMiB: Int?
        var environment: [String] = []
        var network: Network?
        var json = false
        var maximumSeconds = ContainerRunPlan.defaultMaximumSeconds
    }

    /// The places a plan depends on, injected so that a test fixes them.
    struct Surroundings {
        var workingDirectory: URL
        var temporaryDirectory: URL
        /// Makes the default scratch directory's name unique.
        var token: String
        var home: URL

        static func current() -> Self {
            Self(
                workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
                temporaryDirectory: FileManager.default.temporaryDirectory,
                token: UUID().uuidString.lowercased(),
                home: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    let options: Options
    /// The absolute scratch directory the runner is given.
    let scratch: URL
    /// Whether ``scratch`` is a fresh directory of this run's own, not one the caller named.
    let isFresh: Bool

    /// Checks `options`.
    ///
    /// - Throws: ``ToolError`` with the usage status, naming the option that is wrong. Without `--boot` nothing else is
    ///   looked at: the run is refused.
    static func make(_ options: Options, in surroundings: Surroundings = .current()) throws -> Self {
        guard options.confirmed else {
            throw ToolError.usage(
                """
                container-run boots a real virtual machine. Only the repository owner, or an agent the owner has authorised \
                for the session, runs real guests (CONTRIBUTING.md, "Real-guest runs"). Pass --boot to confirm that this run is \
                authorised.
                """)
        }
        if let cpus = options.cpus, !(1...maximumCPUs).contains(cpus) {
            throw ToolError.usage("--cpus must be from 1 to \(maximumCPUs), the cap of a real-guest run, not \(cpus)")
        }
        if let memory = options.memoryMiB, !(minimumMemoryMiB...maximumMemoryMiB).contains(memory) {
            throw ToolError.usage(
                "--memory must be from \(minimumMemoryMiB) to \(maximumMemoryMiB) MiB, the cap of a real-guest run, not \(memory)")
        }
        guard (1...maximumSecondsLimit).contains(options.maximumSeconds) else {
            throw ToolError.usage("--max-seconds must be from 1 to \(maximumSecondsLimit)")
        }
        if let requested = options.scratch {
            let scratch = try GuestScratch(path: requested, workingDirectory: surroundings.workingDirectory, home: surroundings.home)
            return Self(options: options, scratch: scratch.root, isFresh: false)
        }
        let fresh = surroundings.temporaryDirectory.appending(path: "vmr-container-run-\(surroundings.token)", directoryHint: .isDirectory)
        return Self(options: options, scratch: fresh.standardizedFileURL, isFresh: true)
    }

    /// The runner's arguments, in the order its usage lists them; an option that was not given is left out, so the runner's
    /// own default applies.
    var runnerArguments: [String] {
        var arguments = [scratch.path]
        if let image = options.image { arguments += ["--image", image] }
        for argument in options.command { arguments += ["--command", argument] }
        if let cpus = options.cpus { arguments += ["--cpus", "\(cpus)"] }
        if let memory = options.memoryMiB { arguments += ["--memory", "\(memory)"] }
        for entry in options.environment { arguments += ["--env", entry] }
        if let network = options.network { arguments += ["--network", network.rawValue] }
        if options.json { arguments.append("--json") }
        return arguments
    }
}
