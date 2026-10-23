import ControlProtocol
import Foundation
import Synchronization

/// A control service for the end-to-end tests of `vmr control`: the library's own listener on a socket in a short private
/// folder under `/tmp`, its token store in the same folder, and machines held in memory. Nothing of the app runs and no
/// machine starts. `stop()` ends it and removes the folder.
struct ControlFixture: Sendable {
    let folder: URL
    let socket: String
    let store: ControlTokenStore
    let machines: MemoryMachines
    private let listener: ControlListener

    /// Serves `machines` on `c.sock` in a new folder; a local socket path holds about 100 bytes, so the folder is short.
    static func start(machines list: [ControlMachine]) throws -> Self {
        let folder = URL(filePath: "/tmp/vmr-cf-\(String(UInt32.random(in: 0...UInt32.max), radix: 16))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let store = try ControlTokenStore(file: folder.appending(path: "tokens.json"))
            let machines = MemoryMachines(list)
            let dispatcher = ControlDispatcher(tokens: store, machines: machines, report: { _ in })
            let socket = folder.appending(path: "c.sock").path
            let listener = try ControlListener(path: socket, connection: ControlConnection(dispatcher: dispatcher))
            return Self(folder: folder, socket: socket, store: store, machines: machines, listener: listener)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// A new token with `capabilities`, as the environment `vmr control` reads it from.
    func environment(_ capabilities: Set<ControlCapability>) throws -> [String: String] {
        ["VMR_CONTROL_TOKEN": try store.create(name: "test", capabilities: capabilities).secret]
    }

    func stop() async {
        listener.stop()
        await listener.waitUntilStopped()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Machines held in memory: the list the service reports, and every start and stop it was asked for.
final class MemoryMachines: ControlMachines {
    private let state: Mutex<(list: [ControlMachine], requests: [String])>

    init(_ list: [ControlMachine]) { state = Mutex((list, [])) }

    /// The starts and stops asked for, oldest first: `start <id>`, `stop <id>`, `stop <id> force`.
    var requests: [String] { state.withLock { $0.requests } }

    func machines() async -> [ControlMachine] { state.withLock { $0.list } }

    func start(_ id: UUID) async -> ControlOutcome {
        record("start \(id.uuidString)")
        return .done(.running)
    }

    func stop(_ id: UUID, force: Bool) async -> ControlOutcome {
        record(force ? "stop \(id.uuidString) force" : "stop \(id.uuidString)")
        return .done(force ? .stopped : .shuttingDown)
    }

    private func record(_ request: String) { state.withLock { $0.requests.append(request) } }
}
