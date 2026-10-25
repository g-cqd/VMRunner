import Foundation

/// Builds the workload of a container machine: the container runner shipped inside the app, started with the machine's
/// container settings and its own working folder.
struct ContainerMachineFactory: MachineFactory {
    static let missingRunnerMessage =
        "This build of the app does not include the container runner; build it with vmr build-app."

    /// Where the app bundle keeps the runner. A build that is not an app bundle has none there.
    static var bundledRunner: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/ContainerRunner") }

    let runner: URL
    /// The organisation's policy, read at each start so a change reaches a machine that was made before it.
    private let policy: () -> ManagedPreferences

    init(runner: URL = Self.bundledRunner, policy: @escaping () -> ManagedPreferences = { .current }) {
        self.runner = runner
        self.policy = policy
    }

    func prepare(
        _ config: VMConfig, bundle: VMBundle, display: (width: Int, height: Int), suspendAllowed: Bool
    ) async throws -> PreparedMachine {
        guard !policy().isLocked(.allowContainers) else {
            throw ContainerProcessError(reason: ManagedPreferences.containersDeniedMessage)
        }
        guard FileManager.default.isExecutableFile(atPath: runner.path) else {
            throw ContainerProcessError(reason: Self.missingRunnerMessage)
        }
        guard let spec = config.container else {
            throw ContainerProcessError(reason: "“\(config.name)” has no container settings.")
        }
        let scratch = bundle.containerScratch
        let process = ContainerProcess(executable: runner, arguments: ContainerRunnerArguments.make(for: spec, scratch: scratch))
        return PreparedMachine(
            machine: ContainerWorkload(process: process, scratch: scratch), network: nil,
            suspend: .unavailable(reason: "A container can't be suspended."))
    }
}
