import ControlProtocol
import Foundation
import VirtioGPU

/// The library as the control service sees it (ADR-0056): every machine with its state and its agent access, and a start, a
/// stop and a screenshot that refuse a machine whose agent access is off, even if a caller got past the dispatcher's check, and
/// the end of a container's output log under the same rule. A screenshot is the picture of a custom GPU's screen and nothing
/// else. While the organisation keeps the service off, it lists nothing and refuses everything, from the next call on.
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

    func screenshot(_ id: UUID) async -> ControlScreenshotOutcome {
        guard !denied else { return .refused(Self.closedMessage) }
        let frame: ScanoutUpdate
        switch await Self.frame(of: id, in: library) {
        case .success(let found): frame = found
        case .failure(let refusal): return .refused(refusal.reason)
        }
        guard let shot = await Self.encode(frame) else { return .refused("The screenshot could not be made.") }
        return .done(ControlScreenshot(id: id, width: shot.width, height: shot.height, png: shot.data))
    }

    /// Whether the organisation keeps the service off, read now (the same test `ControlService.isEnabled` makes).
    private var denied: Bool { policy().isLocked(.allowControlService) }

    /// The answer while the organisation keeps the service off.
    private static let closedMessage = "Your organisation does not allow the control service."
    private static let closed = ControlOutcome.refused(closedMessage)

    /// Why a machine's screen gives no picture, as a sentence.
    private struct Refusal: Error {
        let reason: String
    }

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

    @MainActor private static func frame(of id: UUID, in library: VMLibrary) -> Result<ScanoutUpdate, Refusal> {
        guard library.machine(id)?.agentAccess == true else { return .failure(Refusal(reason: "Agent access is off for this machine.")) }
        let controller = library.controller(for: id)
        guard controller.state == .running else { return .failure(Refusal(reason: "The machine is not running.")) }
        guard let screen = (controller.guest as Any as? any GuestMachine)?.customDisplay?.screen else {
            return .failure(Refusal(reason: "Screenshots need the custom GPU for now."))
        }
        guard let frame = screen.frame else { return .failure(Refusal(reason: "The guest has not drawn anything yet.")) }
        return .success(frame)
    }

    /// Off the main actor: a picture is a copy of every byte of it, and noise is encoded more than once.
    @concurrent private static func encode(_ frame: ScanoutUpdate) async -> ScreenshotPNG.Picture? {
        ScreenshotPNG.picture(of: frame)
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
