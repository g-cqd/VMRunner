public import Foundation

/// What the spike was asked to do.
public enum SpikeRequest: Equatable, Sendable {
    case run(SpikeArguments)
    case help
}

/// Why the command line was refused. The text is what the spike prints before its usage.
public enum SpikeArgumentError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingScratchDirectory
    case extraArgument(String)
    case unknownOption(String)

    public var description: String {
        switch self {
        case .missingScratchDirectory: "the scratch directory is missing"
        case .extraArgument(let argument): "unexpected argument '\(argument)'"
        case .unknownOption(let option): "unknown option '\(option)'"
        }
    }
}

/// The validated command line of the container spike: one scratch directory.
public struct SpikeArguments: Equatable, Sendable {
    public static let usage = """
        usage: ContainerSpike <scratch-directory>

        Pulls alpine, boots it in a lightweight virtual machine, runs `uname -a` and prints the output and the exit status.
        Every file the spike creates (kernel, image store, container root) lives under <scratch-directory>.
        """

    /// The absolute, standardized scratch directory.
    public let scratch: URL

    /// Reads `arguments` (the program name already removed). A relative scratch directory is taken from `currentDirectory`.
    ///
    /// - Throws: ``SpikeArgumentError``.
    public static func parse(_ arguments: [String], currentDirectory: URL) throws(SpikeArgumentError) -> SpikeRequest {
        var scratch: String?
        for argument in arguments {
            switch argument {
            case "-h", "--help":
                return .help
            case _ where argument.hasPrefix("-"):
                throw .unknownOption(argument)
            default:
                guard scratch == nil else { throw .extraArgument(argument) }
                scratch = argument
            }
        }
        guard let scratch, !scratch.isEmpty else { throw .missingScratchDirectory }
        let directory = URL(fileURLWithPath: scratch, isDirectory: true, relativeTo: currentDirectory).standardizedFileURL
        return .run(Self(scratch: directory))
    }
}

/// Where the spike keeps its files, all under the scratch directory.
public struct SpikeLayout: Equatable, Sendable {
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
