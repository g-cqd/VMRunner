import ControlProtocol
import Foundation

/// The library as the control service sees it (ADR-0056): every machine with its state and its agent access, and a start and
/// a stop that refuse a machine whose agent access is off, even if a caller got past the dispatcher's check.
struct LibraryControlMachines: ControlMachines {
    let library: VMLibrary

    func machines() async -> [ControlMachine] { await Self.list(library) }

    func start(_ id: UUID) async -> ControlOutcome { await Self.start(id, in: library) }

    func stop(_ id: UUID, force: Bool) async -> ControlOutcome { await Self.stop(id, force: force, in: library) }

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
