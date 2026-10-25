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
    case invalidImage
    case tooManyCommandArguments
    case invalidCommandArgument(position: Int)
    case invalidCPUs(String)
    case invalidMemory(String)
    case invalidEnvironment(name: String)
    case tooManyEnvironmentVariables
    case duplicateEnvironment(name: String)

    public var description: String {
        switch self {
        case .missingScratchDirectory: "the scratch directory is missing"
        case .extraArgument(let argument): "unexpected argument '\(argument)'"
        case .unknownOption(let option): "unknown option '\(option)'"
        case .missingValue(let option): "\(option) needs a value"
        case .unknownNetwork(let value): "unknown network '\(value)' (none or loopback)"
        case .invalidImage:
            "the image reference must be 1 to \(RunnerArguments.maximumImageBytes) bytes without whitespace or control characters"
        case .tooManyCommandArguments: "at most \(RunnerArguments.maximumCommandArguments) --command arguments are allowed"
        case .invalidCommandArgument(let position):
            "--command argument \(position) is longer than \(RunnerArguments.maximumCommandArgumentBytes) bytes or contains a NUL"
        case .invalidCPUs(let value):
            "invalid --cpus '\(value)' (a whole number from \(RunnerArguments.cpuRange.lowerBound) to "
                + "\(RunnerArguments.cpuRange.upperBound))"
        case .invalidMemory(let value):
            "invalid --memory '\(value)' (MiB, a whole number from \(RunnerArguments.memoryRange.lowerBound) to "
                + "\(RunnerArguments.memoryRange.upperBound))"
        case .invalidEnvironment(let name):
            "invalid --env '\(name)' (NAME=value; NAME is letters, digits and underscores and does not start with a digit; "
                + "the value has no NUL or newline)"
        case .tooManyEnvironmentVariables: "at most \(RunnerArguments.maximumEnvironmentVariables) --env entries are allowed"
        case .duplicateEnvironment(let name): "--env '\(name)' is given more than once"
        }
    }
}

/// The validated command line of the container runner: the scratch directory, which network the container gets, and what
/// to run (image, command, size, environment). `json` switches the output to one event per line.
public struct RunnerArguments: Equatable, Sendable {
    /// How the container is attached to a network.
    public enum Network: String, Equatable, Sendable {
        /// No network device: the baseline run (pull, boot, `uname -a`, exit status).
        case none
        /// A network device whose frames go to a socketpair read by the runner itself.
        case loopback
    }

    public static let defaultImage = "docker.io/library/alpine:3.24.2"
    public static let defaultCPUs = 2
    public static let defaultMemoryMiB = 512
    public static let cpuRange = 1...16
    public static let memoryRange = 128...16384
    static let maximumImageBytes = 255
    static let maximumCommandArguments = 64
    static let maximumCommandArgumentBytes = 4096
    static let maximumEnvironmentVariables = 64

    public static let usage = """
        usage: ContainerRunner <scratch-directory> [--network none|loopback] [--image <reference>] [--command <argument>]...
                               [--cpus <n>] [--memory <MiB>] [--env <NAME=value>]... [--json]

        Every file the runner creates (kernel, image store, container root) lives under <scratch-directory>.
        --network none      pull the image, boot it, run the command, print the exit status (default)
        --network loopback  the same, with a network device backed by a socketpair instead of a network; the container
                            pings its gateway and the runner reports the frames the device delivered
        --image             the image to run (default \(defaultImage))
        --command           one argument of the command to run, without a shell; repeat it for each argument. Without it the
                            runner runs `uname -a` and expects the architecture in the output; with it the run passes when
                            the command exits with status 0
        --cpus              virtual processors, \(cpuRange.lowerBound) to \(cpuRange.upperBound) (default \(defaultCPUs))
        --memory            memory in MiB, \(memoryRange.lowerBound) to \(memoryRange.upperBound) (default \(defaultMemoryMiB))
        --env               an environment variable NAME=value for the command; repeat it, once per name
        --json              print one JSON event per line on standard output instead of the report (phase, output, exited,
                            error, finished) and stop the container on a `stop` line or the end of standard input (status 75)
        """

    /// The absolute, standardized scratch directory.
    public let scratch: URL
    public let network: Network
    /// The image reference to pull and run.
    public let image: String
    /// The command, one element per argument; empty runs the baseline `uname -a`.
    public let command: [String]
    public let cpus: Int
    public let memoryMiB: Int
    /// `NAME=value` entries, validated, each name once.
    public let environment: [String]
    /// Whether to print events instead of the report, and to watch standard input for a stop.
    public let json: Bool

    /// Reads `arguments` (the program name already removed). A relative scratch directory is taken from `currentDirectory`.
    ///
    /// - Throws: ``RunnerArgumentError``.
    public static func parse(_ arguments: [String], currentDirectory: URL) throws(RunnerArgumentError) -> RunnerRequest {
        var scratch: String?
        var network = Network.none
        var image = defaultImage
        var command: [String] = []
        var cpus = defaultCPUs
        var memoryMiB = defaultMemoryMiB
        var environment: [String] = []
        var json = false
        var index = 0
        /// The value after `option`; a value may start with a dash (`--command -c`).
        func value(after option: String) throws(RunnerArgumentError) -> String {
            guard index < arguments.count else { throw .missingValue(option: option) }
            index += 1
            return arguments[index - 1]
        }
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "-h", "--help":
                return .help
            case "--network":
                let name = try value(after: argument)
                guard let chosen = Network(rawValue: name) else { throw .unknownNetwork(name) }
                network = chosen
            case "--image":
                image = try validImage(try value(after: argument))
            case "--command":
                try appendCommandArgument(try value(after: argument), to: &command)
            case "--cpus":
                let text = try value(after: argument)
                guard let count = integer(text, in: cpuRange) else { throw .invalidCPUs(text) }
                cpus = count
            case "--memory":
                let text = try value(after: argument)
                guard let mebibytes = integer(text, in: memoryRange) else { throw .invalidMemory(text) }
                memoryMiB = mebibytes
            case "--env":
                try appendEnvironment(try value(after: argument), to: &environment)
            case "--json":
                json = true
            case _ where argument.hasPrefix("-"):
                throw .unknownOption(argument)
            default:
                guard scratch == nil else { throw .extraArgument(argument) }
                scratch = argument
            }
        }
        guard let scratch, !scratch.isEmpty else { throw .missingScratchDirectory }
        let directory = URL(fileURLWithPath: scratch, isDirectory: true, relativeTo: currentDirectory).standardizedFileURL
        return .run(
            Self(
                scratch: directory, network: network, image: image, command: command, cpus: cpus, memoryMiB: memoryMiB,
                environment: environment, json: json))
    }

    /// The name of a `NAME=value` entry: everything before the first `=`, or all of it when there is none.
    static func name(of entry: String) -> Substring {
        entry.prefix { $0 != "=" }
    }

    /// `base` with each entry of the environment applied: an entry replaces the one of the same name, or is added at the end.
    public func environment(merging base: [String]) -> [String] {
        var merged = base
        for entry in environment {
            let name = Self.name(of: entry)
            if let position = merged.firstIndex(where: { Self.name(of: $0) == name }) {
                merged[position] = entry
            } else {
                merged.append(entry)
            }
        }
        return merged
    }

    private static func validImage(_ reference: String) throws(RunnerArgumentError) -> String {
        let forbidden = reference.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control }
        guard !reference.isEmpty, reference.utf8.count <= maximumImageBytes, !forbidden else { throw .invalidImage }
        return reference
    }

    private static func appendCommandArgument(_ argument: String, to command: inout [String]) throws(RunnerArgumentError) {
        guard command.count < maximumCommandArguments else { throw .tooManyCommandArguments }
        guard argument.utf8.count <= maximumCommandArgumentBytes, !argument.utf8.contains(0) else {
            throw .invalidCommandArgument(position: command.count + 1)
        }
        command.append(argument)
    }

    private static func appendEnvironment(_ entry: String, to environment: inout [String]) throws(RunnerArgumentError) {
        let key = name(of: entry)
        let value = entry.dropFirst(key.count + 1)
        let wellFormed = entry.utf8.count > key.utf8.count && isName(key) && !value.utf8.contains(0) && !value.utf8.contains(10)
        guard wellFormed else { throw .invalidEnvironment(name: String(key.prefix(64))) }
        guard environment.count < maximumEnvironmentVariables else { throw .tooManyEnvironmentVariables }
        guard !environment.contains(where: { name(of: $0) == key }) else { throw .duplicateEnvironment(name: String(key)) }
        environment.append(entry)
    }

    /// Letters, digits and underscores, not starting with a digit.
    private static func isName(_ name: Substring) -> Bool {
        guard let first = name.utf8.first, first == 95 || isLetter(first) else { return false }
        return name.utf8.allSatisfy { $0 == 95 || isLetter($0) || isDigit($0) }
    }

    private static func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }

    /// `text` as a whole number inside `range`; digits only, so no sign, no spaces.
    private static func integer(_ text: String, in range: ClosedRange<Int>) -> Int? {
        guard text.utf8.count <= 6, !text.isEmpty, text.utf8.allSatisfy(isDigit), let number = Int(text), range.contains(number) else {
            return nil
        }
        return number
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
