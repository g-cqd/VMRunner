import Foundation
import GuestConsole
import VMHelperCore
import Virtualization

/// Boots the machine and waits until it stops, fails, or the run-time limit passes. Only `--start` comes here.
@MainActor
struct MachineRun {
    let descriptor: HelperDescriptor
    let emitter: Emitter
    let runSeconds: Int

    /// How a run ended.
    enum Outcome: Sendable {
        case guestStopped
        case failed(String)
        case timeLimit
    }

    func run() async throws {
        guard VZVirtualMachine.isSupported else {
            throw HelperFailure.configurationRejected("virtualization is not supported on this host")
        }
        let built = try MachineConfiguration.build(descriptor, creatingVariableStore: true)
        // The host end of a file-handle network stays open until the process exits.
        _ = built.hostDescriptor

        // The console is served before the machine starts, so the first client sees the guest's first output.
        let console = try serveConsole(built)
        do {
            try await runMachine(built)
        } catch {
            await stop(console)
            throw error
        }
        await stop(console)
    }

    private func serveConsole(_ built: MachineConfiguration.Built) throws -> ConsoleBridge? {
        guard let settings = descriptor.console, let host = built.consoleDescriptor else { return nil }
        let bridge: ConsoleBridge
        do {
            bridge = try ConsoleBridge(guestDescriptor: host, socketPath: settings.socket)
        } catch {
            close(host)
            throw HelperFailure.virtualMachine("cannot serve the console on \(settings.socket): \(error)")
        }
        bridge.start()
        emitter.emit(.consoleReady, message: settings.socket)
        return bridge
    }

    private func stop(_ console: ConsoleBridge?) async {
        guard let console else { return }
        console.stop()
        await console.waitUntilFinished()
    }

    private func runMachine(_ built: MachineConfiguration.Built) async throws {
        let machine = VZVirtualMachine(configuration: built.configuration)
        let delegate = Delegate()
        machine.delegate = delegate

        emitter.emit(.booting)
        do {
            try await machine.start()
        } catch {
            throw HelperFailure.virtualMachine("the machine failed to start: \(error.localizedDescription)")
        }
        emitter.emit(.running)

        let limit = Task { @MainActor in
            try await Task.sleep(for: .seconds(runSeconds))
            delegate.finish(.timeLimit)
        }
        defer { limit.cancel() }

        switch await delegate.firstOutcome() {
        case .guestStopped:
            emitter.emit(.stopped, message: "guest")
        case .timeLimit:
            do {
                try await machine.stop()
            } catch {
                throw HelperFailure.virtualMachine("the machine did not stop at the time limit: \(error.localizedDescription)")
            }
            emitter.emit(.stopped, message: "time limit")
        case .failed(let message):
            throw HelperFailure.virtualMachine("the machine stopped with an error: \(message)")
        }
    }

    /// Turns the framework's delegate callbacks (and the time limit) into one awaited outcome.
    final class Delegate: NSObject, VZVirtualMachineDelegate, Sendable {
        private let stream: AsyncStream<Outcome>
        private let continuation: AsyncStream<Outcome>.Continuation

        override init() {
            (stream, continuation) = AsyncStream.makeStream(of: Outcome.self)
            super.init()
        }

        func firstOutcome() async -> Outcome {
            for await outcome in stream { return outcome }
            return .failed("the outcome stream ended without a result")
        }

        func finish(_ outcome: Outcome) {
            continuation.yield(outcome)
        }

        func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            continuation.yield(.guestStopped)
        }

        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
            continuation.yield(.failed(error.localizedDescription))
        }
    }
}
