import ArgumentParser
import Foundation

struct ContainerSignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-sign",
        abstract: "Build the container runner and sign it with the virtualization entitlement.",
        discussion: """
            Builds the ContainerRunner product, ad-hoc signs it with the hardened runtime and \
            Resources/ContainerRunner.entitlements, then verifies the signature, the effective entitlements and the runtime \
            flag. It never runs the runner: that boots a virtual machine, which only its owner does (see \
            docs/research/containers-2026-10.md).
            """
    )

    @OptionGroup var project: ProjectOptions

    @Argument(help: "The build configuration, debug or release (default: release).")
    var configuration: AppBundler.Configuration?

    @Option(name: .long, help: ArgumentHelp("Sign this executable instead of building one.", valueName: "path"))
    var binary: String?

    func run() async throws {
        try await perform {
            let signer = ContainerSigner(
                root: try project.packageRoot(),
                binary: binary.map { URL(fileURLWithPath: $0) },
                configuration: configuration ?? .release
            )
            try await signer.run()
            return 0
        }
    }
}
