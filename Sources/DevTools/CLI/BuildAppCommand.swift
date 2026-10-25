import ArgumentParser
import Foundation

extension AppBundler.Configuration: ExpressibleByArgument, EnumerableFlag {}

struct BuildAppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-app",
        abstract: "Build, sign and verify build/VMRunner.app.",
        discussion: """
            Builds the app, ad-hoc signs it with the hardened runtime and the entitlements it needs, then verifies \
            the signature, the effective entitlements (nothing added or dropped, never get-task-allow in a release \
            build) and the runtime flag. The container runner is built from Packages/Containers in the same \
            configuration, signed with Resources/ContainerRunner.entitlements (virtualization only) and embedded as \
            Contents/Helpers/ContainerRunner before the app is signed, so the app's signature seals it.
            """
    )

    @OptionGroup var project: ProjectOptions

    @Argument(help: "The build configuration, debug or release (default: release).")
    var configuration: AppBundler.Configuration?

    @Flag(help: "The build configuration, as a flag.")
    var flaggedConfiguration: AppBundler.Configuration?

    @Flag(
        help: """
            Sign with Resources/VMRunner.hardened.entitlements: Apple's Enhanced Security (hardened process and heap, \
            read-only dyld state, platform restrictions v2).
            """
    )
    var hardened = false

    @Flag(help: "Build an arm64e (pointer authentication) executable, in its own scratch path (.build-arm64e).")
    var arm64e = false

    @Option(name: .long, help: ArgumentHelp("Embed this executable, signed here, instead of building the runner.", valueName: "path"))
    var containerRunner: String?

    func validate() throws {
        if let configuration, let flaggedConfiguration, configuration != flaggedConfiguration {
            throw ValidationError("conflicting build configurations: \(configuration.rawValue) and --\(flaggedConfiguration.rawValue)")
        }
    }

    func run() async throws {
        try await perform {
            let options = AppBundler.Options(
                configuration: configuration ?? flaggedConfiguration ?? .release,
                hardened: hardened,
                arm64e: arm64e,
                containerRunner: containerRunner.map { URL(fileURLWithPath: $0) }
            )
            try await AppBundler(root: try project.packageRoot(), options: options).run()
            return 0
        }
    }
}
