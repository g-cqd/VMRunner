import Foundation
import VMHelperCore
import Virtualization

/// The headless helper of the sandbox helper: boots one Linux guest from a JSON descriptor and reports over standard output.
///
///     VMHelper --dry-run [--descriptor PATH|-]            build and validate the configuration, start nothing
///     VMHelper --probe   [--descriptor PATH|-]            try the operations a helper needs, inside the sandbox it runs in
///     VMHelper --start   [--descriptor PATH|-] [--run-seconds N] [--commands]   boot the machine (the owner's run)
///
/// With `--commands` the helper reads command lines from standard input while the machine runs (`HelperCommand`: a new network
/// policy, the counters); the descriptor then needs a path. The descriptor comes from `PATH`, or from standard input when the
/// path is `-` or absent. Standard output carries one JSON
/// event per line (`HelperEvent`); the guest's serial console goes to standard error, unless the descriptor names a console
/// socket, in which case it is served there. The exit status is the `sysexits.h` value of `HelperFailure`, or 0.
@main
struct VMHelper {
    enum Mode: String {
        case dryRun = "--dry-run"
        case probe = "--probe"
        case start = "--start"
    }

    struct Arguments {
        var mode: Mode
        var descriptorPath: String?
        var runSeconds: Int
        var takesCommands: Bool

        static let defaultRunSeconds = 30

        init(_ arguments: [String]) throws {
            var mode: Mode?
            var path: String?
            var seconds = Self.defaultRunSeconds
            var commands = false
            var rest = arguments.makeIterator()
            while let argument = rest.next() {
                if let requested = Mode(rawValue: argument) {
                    guard mode == nil else { throw HelperFailure.usage("give exactly one of --dry-run, --probe and --start") }
                    mode = requested
                } else if argument == "--descriptor" {
                    guard let value = rest.next() else { throw HelperFailure.usage("--descriptor needs a path, or - for standard input") }
                    path = value == "-" ? nil : value
                } else if argument == "--run-seconds" {
                    guard let value = rest.next(), let parsed = Int(value), parsed > 0 else {
                        throw HelperFailure.usage("--run-seconds needs a positive number")
                    }
                    seconds = parsed
                } else if argument == "--commands" {
                    commands = true
                } else {
                    throw HelperFailure.usage("unknown argument \(argument)")
                }
            }
            guard let mode else { throw HelperFailure.usage("give one of --dry-run, --probe and --start") }
            guard !commands || (mode == .start && path != nil) else {
                throw HelperFailure.usage("--commands goes with --start and a --descriptor path: standard input carries the commands")
            }
            self.mode = mode
            descriptorPath = path
            runSeconds = seconds
            takesCommands = commands
        }
    }

    @MainActor
    static func main() async {
        let emitter = Emitter()
        let status: Int32
        do {
            status = try await run(Arguments(Array(CommandLine.arguments.dropFirst())), emitter)
        } catch let failure as HelperFailure {
            emitter.emit(.error, message: failure.message)
            status = failure.exitStatus
        } catch {
            emitter.emit(.error, message: "\(error)")
            status = HelperFailure.virtualMachine("").exitStatus
        }
        exit(status)
    }

    @MainActor
    private static func run(_ arguments: Arguments, _ emitter: Emitter) async throws -> Int32 {
        let descriptor = try readDescriptor(at: arguments.descriptorPath).canonicalized()
        switch arguments.mode {
        case .probe:
            Probe(descriptor: descriptor, emitter: emitter).run()
        case .dryRun:
            // Builds and validates; the machine object is never created, so nothing starts.
            let built = try MachineConfiguration.build(descriptor, creatingVariableStore: false)
            built.release()
            emitter.emit(.validated)
        case .start:
            var run = MachineRun(descriptor: descriptor, emitter: emitter, runSeconds: arguments.runSeconds)
            run.takesCommands = arguments.takesCommands
            try await run.run()
        }
        return 0
    }

    private static func readDescriptor(at path: String?) throws -> HelperDescriptor {
        let data: Data
        if let path {
            guard let contents = FileManager.default.contents(atPath: path) else {
                throw HelperFailure.missingFile("cannot read the descriptor \(path)")
            }
            data = contents
        } else {
            data = (try? FileHandle.standardInput.readToEnd()) ?? Data()
        }
        return try HelperDescriptor.parse(data)
    }
}
