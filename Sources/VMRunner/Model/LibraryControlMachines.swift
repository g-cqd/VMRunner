import ControlProtocol
import Foundation

/// The library as the control service sees it (ADR-0056): every machine with its state and its agent access, and a start and
/// a stop that refuse a machine whose agent access is off, even if a caller got past the dispatcher's check. While the
/// organisation keeps the service off, it lists nothing and refuses everything, from the next call on.
struct LibraryControlMachines: ControlMachines {
    let library: VMLibrary
    /// The organisation's policy as it stands at each call; a test gives its own.
    var policy: @Sendable () -> ManagedPreferences = { ManagedPreferences.current }

    func machines() async -> [ControlMachine] {
        guard !denied else { return [] }
        return await Self.list(library)
    }

    func start(_ id: UUID) async -> ControlOutcome {
        guard !denied else { return Self.closed }
        return await Self.start(id, in: library)
    }

    func stop(_ id: UUID, force: Bool) async -> ControlOutcome {
        guard !denied else { return Self.closed }
        return await Self.stop(id, force: force, in: library)
    }

    /// Whether the organisation keeps the service off, read now (the same test `ControlService.isEnabled` makes).
    private var denied: Bool { policy().isLocked(.allowControlService) }

    /// The answer while the organisation keeps the service off.
    private static let closed = ControlOutcome.refused("Your organisation does not allow the control service.")

    @MainActor private static func list(_ library: VMLibrary) -> [ControlMachine] {
        library.machines.map { config in
            ControlMachine(
                id: config.id, name: config.name, guest: config.guest.rawValue,
                state: ControlState(library.controller(for: config.id).state), agentAccess: config.agentAccess)
        }
    }

    @MainActor private static func start(_ id: UUID, in library: VMLibrary) async -> ControlOutcome {
        guard library.machine(id)?.agentAccess == true else { return .refused("Agent access is off for this machine.") }
        return outcome(await library.startAndWait(id))
    }

    @MainActor private static func stop(_ id: UUID, force: Bool, in library: VMLibrary) async -> ControlOutcome {
        guard library.machine(id)?.agentAccess == true else { return .refused("Agent access is off for this machine.") }
        return outcome(await library.stopAndWait(id, force: force))
    }

    private static func outcome(_ result: MachineCommandResult) -> ControlOutcome {
        switch result {
        case .done(let state): .done(ControlState(state))
        case .refused(let reason), .failed(let reason): .refused(reason)
        }
    }
}

extension ControlState {
    /// What an agent sees of a machine's state: the phases of a start are one `starting`.
    init(_ state: MachineState) {
        switch state {
        case .stopped: self = .stopped
        case .starting: self = .starting
        case .running: self = .running
        case .shuttingDown: self = .shuttingDown
        case .pausing: self = .pausing
        case .paused: self = .paused
        case .resuming: self = .resuming
        case .suspending: self = .suspending
        case .stopping: self = .stopping
        }
    }
}
