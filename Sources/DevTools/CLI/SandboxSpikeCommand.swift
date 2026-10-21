import ArgumentParser
import Foundation
import VMHelperKit

/// Parses an enum option by its raw value; `ExpressibleByArgument` is not adopted for types this package does not own.
private func parseChoice<Value: RawRepresentable & CaseIterable>(_ text: String) throws -> Value where Value.RawValue == String {
    guard let value = Value(rawValue: text) else {
        throw ValidationError("'\(text)' is not one of \(Value.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    return value
}

struct SandboxSpikeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sandbox-spike",
        abstract: "Run the headless helper under App Sandbox or a Seatbelt profile and report what the sandbox refused.",
        discussion: """
            The spike of roadmap 0025: docs/research/sandboxing-2026-10.md says what it measures and how to read it. \
            Nothing here starts a virtual machine unless `run` gets --boot, which only the repository owner passes.
            """,
        subcommands: [Run.self, Profile.self]
    )

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Probe, validate and (with --boot) boot a descriptor under an engine, then print the report.",
            discussion: """
                Builds the helper, signs it for the engine (App Sandbox: a bundle whose entitlements carry the descriptor's \
                paths; Seatbelt: the plain helper under a profile generated from the descriptor; none: the plain helper), \
                then launches it: --probe (the operations a helper needs, tried inside the sandbox), --dry-run (the \
                configuration is built and validated, nothing starts) and, with --boot, --start. After each launch the \
                sandbox denials of the helper's pid are read from the unified log. Without --boot no machine exists.
                """
        )

        @OptionGroup var project: ProjectOptions

        @Option(
            name: .long, help: ArgumentHelp("Where the helper runs: none, seatbelt or app-sandbox.", valueName: "engine"),
            transform: { try parseChoice($0) as SandboxEngine })
        var engine: SandboxEngine

        @Option(
            name: .long,
            help: ArgumentHelp(
                "What the engine allows: standard (host sockets, if the descriptor needs them) or strict.", valueName: "level"),
            transform: { try parseChoice($0) as SandboxLevel })
        var level: SandboxLevel = .standard

        @Option(name: .long, help: ArgumentHelp("The helper's JSON descriptor.", valueName: "file"))
        var descriptor: String

        @Flag(
            help: """
                START A VIRTUAL MACHINE. Only the repository owner passes this; agents and CI never do. Without it the run \
                probes and validates and no machine is created.
                """
        )
        var boot = false

        @Option(name: .long, help: ArgumentHelp("With --boot: seconds the machine runs before the helper stops it.", valueName: "seconds"))
        var runSeconds = SandboxSpike.defaultRunSeconds

        @Option(
            name: .long, help: ArgumentHelp("The helper's build configuration: debug or release.", valueName: "configuration"),
            transform: { try parseChoice($0) as AppBundler.Configuration })
        var configuration: AppBundler.Configuration = .release

        @Option(name: .long, help: ArgumentHelp("A helper binary built already, instead of building one.", valueName: "path"))
        var helper: String?

        func validate() throws {
            guard runSeconds > 0 else { throw ValidationError("--run-seconds must be positive") }
        }

        func run() async throws {
            try await perform {
                let root = try project.packageRoot()
                var options = SandboxSpike.Options(
                    engine: engine, level: level, descriptor: URL(fileURLWithPath: descriptor, relativeTo: project.workingDirectory()))
                options.boot = boot
                options.runSeconds = runSeconds
                options.configuration = configuration
                options.prebuilt = helper.map { URL(fileURLWithPath: $0, relativeTo: project.workingDirectory()).standardizedFileURL }
                return try await SandboxSpike(root: root, options: options).run()
            }
        }
    }

    struct Profile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the Seatbelt profile generated for a descriptor.",
            discussion: """
                The profile `run --engine seatbelt` writes, without building or launching anything. The helper path in it is \
                where `run` puts the signed helper, build/sandbox-spike/plain/VMHelper, unless --helper names another.
                """
        )

        @OptionGroup var project: ProjectOptions

        @Option(name: .long, help: ArgumentHelp("The helper's JSON descriptor.", valueName: "file"))
        var descriptor: String

        @Option(
            name: .long, help: ArgumentHelp("standard or strict.", valueName: "level"),
            transform: { try parseChoice($0) as SandboxLevel })
        var level: SandboxLevel = .standard

        @Option(name: .long, help: ArgumentHelp("The helper executable the profile lets sandbox-exec run.", valueName: "path"))
        var helper: String?

        func run() async throws {
            try await perform {
                let root = try project.packageRoot()
                let loaded = try SandboxSpike.load(descriptor: URL(fileURLWithPath: descriptor, relativeTo: project.workingDirectory()))
                let grants = try SandboxSpike.grants(for: loaded, level: level)
                let helperPath =
                    helper ?? HelperBundler(root: root, configuration: .release, prebuilt: nil).plainHelperURL.path
                do {
                    Output.out(String(try SeatbeltProfile.generate(grants: grants, helperExecutable: helperPath).dropLast()))
                } catch let failure as HelperFailure {
                    throw ToolError(failure)
                }
                return 0
            }
        }
    }
}
