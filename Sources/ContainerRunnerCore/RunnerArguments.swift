public import Foundation

/// What the runner was asked to do.
public enum RunnerRequest: Equatable, Sendable {
    case run(RunnerArguments)
    case help
}

/// Why the command line was refused. The text is what the runner prints before its usage.
public enum RunnerArgumentError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingScratchDirectory
    case extraArgument(String)
    case unknownOption(String)
    case missingValue(option: String)
    case unknownNetwork(String)

    public var description: String {
        switch self {
        case .missingScratchDirectory: "the scratch directory is missing"
        case .extraArgument(let argument): "unexpected argument '\(argument)'"
        case .unknownOption(let option): "unknown option '\(option)'"
        case .missingValue(let option): "\(option) needs a value"
        case .unknownNetwork(let value): "unknown network '\(value)' (none or loopback)"
        }
    }
}

/// The validated command line of the container runner: one scratch directory and which network the container gets.
public struct RunnerArguments: Equatable, Sendable {
    /// How the container is attached to a network.
    public enum Network: String, Equatable, Sendable {
        /// No network device: the baseline run (pull, boot, `uname -a`, exit status).
        case none
        /// A network device whose frames go to a socketpair read by the runner itself.
        case loopback
    }

    public static let usage = """
        usage: ContainerRunner <scratch-directory> [--network none|loopback]

        Every file the runner creates (kernel, image store, container root) lives under <scratch-directory>.
        --network none      pull alpine, boot it, run `uname -a`, print the exit status (default)
        --network loopback  the same, with a network device backed by a socketpair instead of a network; the container
                            pings its gateway and the runner reports the frames the device delivered
        """

    /// The absolute, standardized scratch directory.
    public let scratch: URL
    public let network: Network

    /// Reads `arguments` (the program name already removed). A relative scratch directory is taken from `currentDirectory`.
    ///
    /// - Throws: ``RunnerArgumentError``.
    public static func parse(_ arguments: [String], currentDirectory: URL) throws(RunnerArgumentError) -> RunnerRequest {
        var scratch: String?
        var network = Network.none
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "-h", "--help":
                return .help
            case "--network":
                guard index < arguments.count else { throw .missingValue(option: argument) }
                guard let chosen = Network(rawValue: arguments[index]) else { throw .unknownNetwork(arguments[index]) }
                network = chosen
                index += 1
            case _ where argument.hasPrefix("-"):
                throw .unknownOption(argument)
            default:
                guard scratch == nil else { throw .extraArgument(argument) }
                scratch = argument
            }
        }
        guard let scratch, !scratch.isEmpty else { throw .missingScratchDirectory }
        let directory = URL(fileURLWithPath: scratch, isDirectory: true, relativeTo: currentDirectory).standardizedFileURL
        return .run(Self(scratch: directory, network: network))
    }
}

/// Where the runner keeps its files, all under the scratch directory.
public struct RunnerLayout: Equatable, Sendable {
    public let scratch: URL

    public init(scratch: URL) {
        self.scratch = scratch
    }

    /// The downloaded kernel archive.
    public var kernelArchive: URL { scratch.appending(path: "downloads/\(KernelArchive.fileName)", directoryHint: .notDirectory) }
    /// Where `tar` unpacks the one kernel member.
    public var kernelStaging: URL { scratch.appending(path: "kernel-staging", directoryHint: .isDirectory) }
    /// The kernel the container boots.
    public var kernelImage: URL { scratch.appending(path: "kernel/vmlinux", directoryHint: .notDirectory) }
    /// The image store and container root passed to the container manager.
    public var imageStore: URL { scratch.appending(path: "store", directoryHint: .isDirectory) }
}
