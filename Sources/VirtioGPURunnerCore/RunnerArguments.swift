/// Why a command line was refused.
package enum RunnerArgumentError: Error, Equatable, CustomStringConvertible {
    case unknownOption(String)
    case missingValue(option: String)
    case notANumber(option: String, value: String)
    case outOfRange(option: String, value: Int, allowed: ClosedRange<Int>)
    case missing(option: String)
    case notAbsolute(option: String, path: String)
    case refusedDirectory(String)

    package var description: String {
        switch self {
        case .unknownOption(let option): "unknown option '\(option)'"
        case .missingValue(let option): "\(option) needs a value"
        case .notANumber(let option, let value): "\(option) takes a whole number, not '\(value)'"
        case .outOfRange(let option, let value, let allowed):
            "\(option) \(value) is outside \(allowed.lowerBound)...\(allowed.upperBound)"
        case .missing(let option): "\(option) is required"
        case .notAbsolute(let option, let path): "\(option) needs an absolute path without '..', not '\(path)'"
        case .refusedDirectory(let reason): reason
        }
    }
}

/// What one boot of the runner uses: a scratch directory for everything it writes, a raw disk image, an optional seed image,
/// and caps on the guest's resources and run time.
package struct RunnerOptions: Equatable, Sendable {
    package var directory: String
    package var disk: String
    package var seed: String?
    package var cpuCount = 2
    package var memoryMiB = 2048
    package var maxSeconds = 900
    /// Build and validate the configuration, start nothing.
    package var dryRun = false
    /// Seconds after the driver is ready at which the device sets the display event in its configuration space, to see
    /// whether that change reaches the guest.
    package var probeConfigChangeSeconds: Int?
    /// Write the newest scanout picture to `scanout.png`, at most once a second and once at the end.
    package var headlessDump = false
    /// Show the scanout in a window of the runner's own.
    package var window = false

    package static let cpuRange = 1...2
    package static let memoryRange = 1024...2048
    package static let secondsRange = 10...3600
    package static let probeRange = 1...600

    /// The machine's files inside the scratch directory.
    package var variableStorePath: String { directory + "/efi-vars.fd" }
    package var consoleLogPath: String { directory + "/console.log" }
    package var pidPath: String { directory + "/runner.pid" }
    package var commandsLogPath: String { directory + "/commands.log" }
    package var scanoutPNGPath: String { directory + "/scanout.png" }
}

/// What the command line asks for.
package enum RunnerRequest: Equatable, Sendable {
    case help
    case describe
    case run(RunnerOptions)
}

/// The runner's command line, read without touching the file system.
package enum RunnerArguments {
    package static let usage = """
        usage: VirtioGPURunner --directory <scratch> --disk <raw image> [--seed <iso>] [options]
               VirtioGPURunner --describe | --help

        Boots one Linux guest whose only display is the host-implemented virtio GPU device. Needs macOS 27 or later.
          --directory <path>   absolute scratch directory for everything the run writes (not /, the home folder or ~/Library)
          --disk <path>        the guest's raw, bootable disk image (EFI)
          --seed <path>        an image attached read-only as a second disk (a cloud-init seed)
          --cpus <n>           1 to 2 (default 2)
          --memory-mib <n>     1024 to 2048 (default 2048)
          --max-seconds <n>    10 to 3600 (default 900); the machine is stopped then, whatever it does
          --probe-config-change <s>  1 to 600: that many seconds after the driver is ready, signal a display change through
                               the configuration space and record whether the guest asks for the display information again
          --headless-dump      write the newest scanout picture to scanout.png in the directory (at most once a second)
          --window             show the scanout in a window of the runner's own
          --dry-run            build and validate the configuration, start nothing
          --describe           print the virtio identity and the configuration space the guest sees
        """

    /// Reads `arguments` (the program name already removed). `home` is the user's home folder, refused as a scratch
    /// directory with everything in its `Library`.
    package static func parse(_ arguments: [String], home: String) throws(RunnerArgumentError) -> RunnerRequest {
        var values: [String: String] = [:]
        var dryRun = false
        var headlessDump = false
        var window = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "-h", "--help": return .help
            case "--describe": return .describe
            case "--dry-run": dryRun = true
            case "--headless-dump": headlessDump = true
            case "--window": window = true
            case "--directory", "--disk", "--seed", "--cpus", "--memory-mib", "--max-seconds", "--probe-config-change":
                guard index < arguments.count else { throw .missingValue(option: argument) }
                values[argument] = arguments[index]
                index += 1
            default: throw .unknownOption(argument)
            }
        }
        guard let directory = values["--directory"] else { throw .missing(option: "--directory") }
        guard let disk = values["--disk"] else { throw .missing(option: "--disk") }
        var options = RunnerOptions(
            directory: try scratchDirectory(directory, home: home), disk: try absolute(disk, option: "--disk"),
            seed: try values["--seed"].map { path throws(RunnerArgumentError) in try absolute(path, option: "--seed") })
        options.cpuCount = try number(values["--cpus"], option: "--cpus", in: RunnerOptions.cpuRange) ?? options.cpuCount
        options.memoryMiB = try number(values["--memory-mib"], option: "--memory-mib", in: RunnerOptions.memoryRange) ?? options.memoryMiB
        options.maxSeconds =
            try number(values["--max-seconds"], option: "--max-seconds", in: RunnerOptions.secondsRange) ?? options.maxSeconds
        options.probeConfigChangeSeconds = try number(
            values["--probe-config-change"], option: "--probe-config-change", in: RunnerOptions.probeRange)
        options.dryRun = dryRun
        options.headlessDump = headlessDump
        options.window = window
        return .run(options)
    }

    private static func number(_ text: String?, option: String, in range: ClosedRange<Int>) throws(RunnerArgumentError) -> Int? {
        guard let text else { return nil }
        guard let value = Int(text) else { throw .notANumber(option: option, value: text) }
        guard range.contains(value) else { throw .outOfRange(option: option, value: value, allowed: range) }
        return value
    }

    /// `path` without a trailing slash, when it is absolute and has no `.` or `..` component.
    private static func absolute(_ path: String, option: String) throws(RunnerArgumentError) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"), !components.contains(".."), !components.contains(".") else {
            throw .notAbsolute(option: option, path: path)
        }
        return "/" + components.joined(separator: "/")
    }

    /// Refuses the root of the disk, the home folder and anything in its `Library`, by their names (the run creates the
    /// directory itself, so a link planted there in advance is the caller's own).
    private static func scratchDirectory(_ path: String, home: String) throws(RunnerArgumentError) -> String {
        let directory = try absolute(path, option: "--directory")
        let homeFolder = (try? absolute(home, option: "home")) ?? home
        if directory == "/" { throw .refusedDirectory("the root of the disk is not a scratch directory") }
        if directory == homeFolder { throw .refusedDirectory("your home folder is not a scratch directory") }
        let library = homeFolder + "/Library"
        if directory == library || directory.hasPrefix(library + "/") {
            throw .refusedDirectory("\(directory) is inside your Library; give a scratch directory under /tmp")
        }
        return directory
    }
}
