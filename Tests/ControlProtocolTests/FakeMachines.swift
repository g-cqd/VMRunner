import ControlProtocol
import Foundation
import Synchronization
import TestKit
import Testing

/// Machines for the tests: a list to report, every start, stop and log read recorded, and a start that waits at `startGate` when
/// set. A log read answers `logOutcome`, or a short text of the machine when none is given.
final class FakeMachines: ControlMachines {
    private let list: Mutex<[ControlMachine]>
    let calls = AsyncEventProbe<String>()
    let startGate: AsyncGate?
    let startOutcome: ControlOutcome
    let logOutcome: ControlLogOutcome?

    init(
        _ machines: [ControlMachine], startGate: AsyncGate? = nil, startOutcome: ControlOutcome = .done(.running),
        logOutcome: ControlLogOutcome? = nil
    ) {
        list = Mutex(machines)
        self.startGate = startGate
        self.startOutcome = startOutcome
        self.logOutcome = logOutcome
    }

    func machines() async -> [ControlMachine] { list.withLock { $0 } }

    func start(_ id: UUID) async -> ControlOutcome {
        calls.record("start \(id.uuidString)")
        if let startGate { try? await startGate.waitUntilOpen() }
        return startOutcome
    }

    func stop(_ id: UUID, force: Bool) async -> ControlOutcome {
        calls.record("stop \(id.uuidString) force=\(force)")
        return .done(force ? .stopped : .shuttingDown)
    }

    func log(_ id: UUID) async -> ControlLogOutcome {
        calls.record("log \(id.uuidString)")
        return logOutcome ?? .text("output of \(id.uuidString)\n", truncated: false)
    }
}

extension ControlMachine {
    static func fake(_ name: String, access: Bool = true, state: ControlState = .stopped) -> ControlMachine {
        Self(id: UUID(), name: name, guest: "linux", state: state, agentAccess: access)
    }
}
