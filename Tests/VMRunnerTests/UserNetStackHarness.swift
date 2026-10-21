import Foundation
import Synchronization
import Testing

@testable import VMRunner

/// Every test that drives a real stack with a blocking scripted guest lives under this suite. They run one at a time:
/// each blocks a cooperative-pool thread while it waits on the guest socket, and several at once could starve the
/// tasks the stack itself needs (its path watcher, the event collector), turning a slow machine into a flaky test.
@Suite(.serialized) enum UserNetIntegration {}

/// Maps names to addresses for the stack's DNS proxy, in place of the system resolver (no internet in tests).
struct StubResolver: HostNameResolver {
    var table: [String: [String]] = [:]
    /// Also answers a CNAME to this canonical name for the given names.
    var canonical: [String: String] = [:]

    func lookup(name: String, recordType: UInt16) async -> DNSLookupResult {
        guard recordType == DNSCode.typeA, let addresses = table[name] else {
            return DNSLookupResult(responseCode: recordType == DNSCode.typeA ? DNSCode.nameError : DNSCode.noError)
        }
        let owner = canonical[name] ?? name
        var records: [DNSRecord] = []
        if let target = canonical[name], let encoded = DNSWire.encodeName(target) {
            records.append(DNSRecord(name: name, type: DNSCode.typeCNAME, ttl: 30, data: encoded))
        }
        for text in addresses { records.append(DNSRecord(name: owner, type: DNSCode.typeA, ttl: 30, data: Wire.be32(ipv4(text)))) }
        return DNSLookupResult(responseCode: DNSCode.noError, records: records)
    }
}

/// Collects a stack's flow events and lets a test await one with a timeout, without sleeping.
final class FlowEventLog: Sendable {
    private struct Waiter {
        let id: Int
        let predicate: @Sendable (FlowEvent) -> Bool
        let continuation: CheckedContinuation<FlowEvent?, Never>
    }

    private struct State {
        var events: [FlowEvent] = []
        var waiters: [Waiter] = []
        var nextID = 0
    }

    private final class Shared: Sendable {
        let state = Mutex(State())
    }

    private let shared = Shared()
    private let collector: Task<Void, Never>

    init(_ stream: AsyncStream<FlowEvent>) {
        let shared = shared
        collector = Task {
            for await event in stream {
                let matched = shared.state.withLock { current -> [Waiter] in
                    current.events.append(event)
                    let ready = current.waiters.filter { $0.predicate(event) }
                    current.waiters.removeAll { waiter in ready.contains { $0.id == waiter.id } }
                    return ready
                }
                for waiter in matched { waiter.continuation.resume(returning: event) }
            }
            let leftover = shared.state.withLock { current -> [Waiter] in
                defer { current.waiters = [] }
                return current.waiters
            }
            for waiter in leftover { waiter.continuation.resume(returning: nil) }
        }
    }

    deinit {
        collector.cancel()
    }

    var events: [FlowEvent] { shared.state.withLock { $0.events } }

    /// Returns once the stack finished its event stream (it did so when it stopped).
    func waitUntilFinished() async {
        await collector.value
    }

    func count(_ predicate: (FlowEvent) -> Bool) -> Int { events.filter(predicate).count }

    /// The first event (already seen or yet to come) matching `predicate`; `nil` after `timeout`.
    func next(timeout: Duration = .seconds(5), where predicate: @escaping @Sendable (FlowEvent) -> Bool) async -> FlowEvent? {
        let id = shared.state.withLock { current -> Int in
            current.nextID += 1
            return current.nextID
        }
        let shared = shared
        let timer = Task {
            try? await Task.sleep(for: timeout)
            let waiter = shared.state.withLock { current -> Waiter? in
                guard let index = current.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return current.waiters.remove(at: index)
            }
            waiter?.continuation.resume(returning: nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            let existing = shared.state.withLock { current -> FlowEvent? in
                if let seen = current.events.first(where: predicate) { return seen }
                current.waiters.append(Waiter(id: id, predicate: predicate, continuation: continuation))
                return nil
            }
            if let existing { continuation.resume(returning: existing) }
        }
    }
}

/// A running stack plus a booted guest, for integration tests.
struct TestNetwork {
    let stack: UserNetStack
    let guest: GuestHarness
    let events: FlowEventLog
}

/// Boots a stack and a scripted guest, runs `body`, and always stops the stack.
func withNetwork(
    policy: NetworkPolicy = CoreRig.openPolicy, resolver: StubResolver = StubResolver(), boot: Bool = true,
    config: UserNetConfig = UserNetConfig(), pathChanges: AsyncStream<Void> = AsyncStream { _ in },
    _ body: (TestNetwork) async throws -> Void
) async throws {
    let made = try UserNetStack.make(config: config, policy: policy, resolver: resolver, pathChanges: { pathChanges })
    let stack = made.stack
    let events = FlowEventLog(stack.flowEvents)
    stack.start()
    let network = TestNetwork(stack: stack, guest: GuestHarness(link: GuestLink(descriptor: made.guestDescriptor)), events: events)
    do {
        if boot { try network.guest.boot() }
        try await body(network)
    } catch {
        await stack.stop()
        close(made.guestDescriptor)
        throw error
    }
    await stack.stop()
    close(made.guestDescriptor)
}
