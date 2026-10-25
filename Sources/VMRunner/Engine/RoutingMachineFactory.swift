import Foundation

/// Sends each start to the factory of what the machine runs: a virtual machine to the framework's factory, a container to
/// the container factory.
struct RoutingMachineFactory: MachineFactory {
    let virtualMachines: any MachineFactory
    let containers: any MachineFactory

    init(
        virtualMachines: any MachineFactory = VZMachineFactory(), containers: any MachineFactory = UnavailableContainerFactory()
    ) {
        self.virtualMachines = virtualMachines
        self.containers = containers
    }

    func prepare(
        _ config: VMConfig, bundle: VMBundle, display: (width: Int, height: Int), suspendAllowed: Bool
    ) async throws -> PreparedMachine {
        switch config.workload {
        case .vm:
            try await virtualMachines.prepare(config, bundle: bundle, display: display, suspendAllowed: suspendAllowed)
        case .container:
            try await containers.prepare(config, bundle: bundle, display: display, suspendAllowed: suspendAllowed)
        }
    }
}

/// The container factory of a build that has no way to run a container: every start fails with a message that says so.
struct UnavailableContainerFactory: MachineFactory {
    struct Unavailable: LocalizedError, Equatable {
        var errorDescription: String? { "Containers are not available in this build." }
    }

    func prepare(
        _ config: VMConfig, bundle: VMBundle, display: (width: Int, height: Int), suspendAllowed: Bool
    ) async throws -> PreparedMachine {
        throw Unavailable()
    }
}
