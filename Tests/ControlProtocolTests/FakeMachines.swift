import ControlProtocol
import Foundation
import Synchronization
import TestKit
import Testing

/// Machines for the tests: a list to report, every start and stop recorded, and a start that waits at `startGate` when set.
final class FakeMachines: ControlMachines {
    private let list: Mutex<[ControlMachine]>
    let calls = AsyncEventProbe<String>()
    let startGate: AsyncGate?
    let startOutcome: ControlOutcome

    init(_ machines: [ControlMachine], startGate: AsyncGate? = nil, startOutcome: ControlOutcome = .done(.running)) {
        list = Mutex(machines)
        self.startGate = startGate
        self.startOutcome = startOutcome
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
}

extension ControlMachine {
    static func fake(_ name: String, access: Bool = true, state: ControlState = .stopped) -> ControlMachine {
        Self(id: UUID(), name: name, guest: "linux", state: state, agentAccess: access)
    }
}
