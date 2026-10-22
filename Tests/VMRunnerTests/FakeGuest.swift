import Foundation
import TestKit
import Testing
import Virtualization

@testable import VMRunner

/// What a fake framework call does, in the framework's own vocabulary.
enum GuestCall: String, Sendable {
    case start, restore, save, pause, resume, requestStop, stop
}

struct FakeGuestError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// A `GuestMachine` that behaves like the framework's machine at the level the controller sees: the same states, calls
/// that are refused in the same states, and calls that wait until the test lets them finish. Nothing here starts a
/// virtual machine.
@MainActor
final class FakeGuest: GuestMachine {
    let name: String
    /// Every call, recorded when it begins (before it waits), as its `GuestCall` raw value.
    let log = AsyncEventProbe<String>()
    private(set) var state = VZVirtualMachine.State.stopped
    /// When false, the guest never reports a state change, as if the framework did not announce them.
    var announcesStateChanges = true

    var virtualMachine: VZVirtualMachine? { nil }
    var canStop: Bool { state == .running || state == .paused }
    var onStateChange: (@MainActor (VZVirtualMachine.State) -> Void)?
    var onGuestStopped: (@MainActor () -> Void)?
    var onStoppedWithError: (@MainActor (_ message: String) -> Void)?

    private var gates: [GuestCall: AsyncGate] = [:]
    private var failures: [GuestCall: String] = [:]

    init(_ name: String = "guest") { self.name = name }

    // MARK: Scripting

    /// The next `call` waits at the gate until the test opens it.
    @discardableResult
    func hold(_ call: GuestCall) -> AsyncGate {
        let gate = AsyncGate()
        gates[call] = gate
        return gate
    }

    /// `call` fails with `message` once it is allowed to finish.
    func fail(_ call: GuestCall, _ message: String) { failures[call] = message }

    func count(_ call: GuestCall) -> Int { log.events.filter { $0 == call.rawValue }.count }

    /// Waits until `call` has been made `times` times in all. Each wait is bounded by the probe's timeout, so a call that
    /// never comes fails the test instead of hanging it.
    func waitFor(_ call: GuestCall, times: Int = 1) async throws {
        while count(call) < times { _ = try await log.wait(forAtLeast: log.count + 1) }
    }

    /// The guest shuts itself down.
    func powerOff() {
        move(to: .stopped)
        onGuestStopped?()
    }

    /// The machine stops with an error.
    func crash(_ message: String) {
        move(to: .error)
        onStoppedWithError?(message)
    }

    // MARK: GuestMachine

    func start() async throws {
        try await run(.start, from: [.stopped], through: .starting, to: .running, failingTo: .stopped)
    }

    func restoreState(from url: URL) async throws {
        try await run(.restore, from: [.stopped], through: .restoring, to: .paused, failingTo: .stopped)
    }

    func saveState(to url: URL) async throws {
        try await run(.save, from: [.paused], through: .saving, to: .paused, failingTo: .paused)
        try Data("memory".utf8).write(to: url)
    }

    func pause() async throws {
        try await run(.pause, from: [.running], through: .pausing, to: .paused, failingTo: .running)
    }

    func resume() async throws {
        try await run(.resume, from: [.paused], through: .resuming, to: .running, failingTo: .paused)
    }

    func requestStop() throws {
        log.record(GuestCall.requestStop.rawValue)
        guard state == .running else { throw FakeGuestError(message: Self.invalidState(state)) }
    }

    func stop() async throws {
        try await run(.stop, from: [.running, .paused], through: .stopping, to: .stopped, failingTo: .stopped)
    }

    // MARK: Plumbing

    static func invalidState(_ state: VZVirtualMachine.State) -> String {
        "Invalid virtual machine state (\(state)). The requested transition is not valid in this state."
    }

    private func run(
        _ call: GuestCall, from allowed: Set<VZVirtualMachine.State>, through transient: VZVirtualMachine.State,
        to success: VZVirtualMachine.State, failingTo failure: VZVirtualMachine.State
    ) async throws {
        log.record(call.rawValue)
        guard allowed.contains(state) else { throw FakeGuestError(message: Self.invalidState(state)) }
        move(to: transient)
        try await gates[call]?.waitUntilOpen()
        if let message = failures[call] {
            move(to: failure)
            throw FakeGuestError(message: message)
        }
        move(to: success)
    }

    private func move(to newState: VZVirtualMachine.State) {
        state = newState
        if announcesStateChanges { onStateChange?(newState) }
    }
}
