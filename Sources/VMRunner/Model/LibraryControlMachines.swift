import ControlProtocol
import Foundation

/// The library as the control service sees it (ADR-0056): every machine with its state and its agent access, and a start and
/// a stop that refuse a machine whose agent access is off, even if a caller got past the dispatcher's check, and the end of a
/// container's output log under the same rule. While the organisation keeps the service off, it lists nothing and refuses
/// everything, from the next call on.
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

    func log(_ id: UUID) async -> ControlLogOutcome {
        guard !denied else { return .refused(Self.closedMessage) }
        switch await Self.logFiles(id, in: library) {
        case .refused(let reason): return .refused(reason)
        case .files(let bundle): return await Self.readLog(of: bundle)
        }
    }

    /// Whether the organisation keeps the service off, read now (the same test `ControlService.isEnabled` makes).
    private var denied: Bool { policy().isLocked(.allowControlService) }

    /// The answer while the organisation keeps the service off.
    private static let closedMessage = "Your organisation does not allow the control service."
    private static let closed = ControlOutcome.refused(closedMessage)

    @MainActor private static func list(_ library: VMLibrary) -> [ControlMachine] {
        library.machines.map { config in
            ControlMachine(
                id: config.id, name: config.name, guest: config.guest.rawValue,
                state: ControlState(library.controller(for: config.id).state), agentAccess: config.agentAccess,
                workload: config.workload.rawValue)
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

    /// Where a machine's log is kept, or why it may not be read.
    private enum LogFiles {
        case files(VMBundle)
        case refused(String)
    }

    @MainActor private static func logFiles(_ id: UUID, in library: VMLibrary) -> LogFiles {
        guard let config = library.machine(id), config.agentAccess else { return .refused("Agent access is off for this machine.") }
        guard config.workload == .container else {
            return .refused("This machine is not a container; only a container machine keeps an output log.")
        }
        return .files(library.bundle(id))
    }

    /// Reads the files off the main actor: they are on a disk, and the reading takes as long as the disk does.
    @concurrent private static func readLog(of bundle: VMBundle) async -> ControlLogOutcome {
        let tail = ContainerOutputFile.tail(
            current: bundle.containerOutput, previous: bundle.previousContainerOutput, limit: ControlLog.maxBytes)
        return .text(tail.text, truncated: tail.truncated)
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
