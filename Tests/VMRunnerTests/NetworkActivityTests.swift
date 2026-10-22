import Foundation
import Observation
import TestKit
import Testing

@testable import VMRunner

/// Drives a `NetworkActivity` with plain streams, a test clock for its batches and recording closures: no sockets, no virtual
/// machine.
@MainActor
private final class ActivityRig {
    let clock = TestClock()
    let activity: NetworkActivity
    let events: AsyncStream<FlowEvent>.Continuation
    let vpn: AsyncStream<GuestVPNState>.Continuation
    let hostFeed: AsyncStream<[InterfaceSnapshot]>.Continuation
    let shutdowns: AsyncEventProbe<Void>
    private(set) var begun = 0
    private(set) var forwarded: [NetworkPolicy] = []
    private(set) var forwardedActions: [ExistingFlowAction] = []

    init(policy: NetworkPolicy = NetworkPolicy()) {
        let (flowStream, flowFeed) = AsyncStream.makeStream(of: FlowEvent.self)
        let (vpnStream, vpnFeed) = AsyncStream.makeStream(of: GuestVPNState.self)
        let (hostStream, hostFeed) = AsyncStream.makeStream(of: [InterfaceSnapshot].self)
        events = flowFeed
        vpn = vpnFeed
        self.hostFeed = hostFeed
        let probe = AsyncEventProbe<Void>()
        shutdowns = probe
        // Closures that touch the rig are built after `self` exists, through a box filled in below.
        let box = Box()
        activity = NetworkActivity(
            policy: policy, events: flowStream, vpnChanges: vpnStream, hostMonitor: VPNMonitor(source: { hostStream }),
            clock: clock,
            begin: { box.rig?.begun += 1 },
            forward: {
                box.rig?.forwarded.append($0)
                box.rig?.forwardedActions.append($1)
            },
            shutdown: { probe.record(()) })
        box.rig = self
    }

    @MainActor final class Box {
        weak var rig: ActivityRig?
    }

    func flow(_ id: UInt64, _ phase: FlowEvent.Phase = .opened) -> FlowEvent {
        FlowEvent(flowID: id, transport: .tcp, phase: phase, remote: (IPv4.make(93, 184, 216, 34), 443), name: nil, time: 0)
    }

    /// Lets the reader tasks run until `condition` holds, moving the batch clock on whenever a batch is waiting for it (bounded,
    /// so a bug fails the test instead of hanging it). The batches are gathered on other threads, so each round also sleeps a
    /// moment of real time to let them run; no result depends on how long that takes.
    func settle(until condition: () -> Bool) async {
        for _ in 0..<5_000 where !condition() {
            if clock.sleeperCount > 0 { clock.advance(by: NetworkActivity.batchInterval) }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Lets the reader tasks run for a while without moving the batch clock.
    func idle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
struct NetworkActivityTests {
    @Test func startBeginsTheStackOnceAndLogsEventsNewestFirst() async throws {
        let rig = ActivityRig()
        rig.activity.start()
        rig.activity.start()
        #expect(rig.begun == 1)
        #expect(rig.activity.isRunning)

        rig.events.yield(rig.flow(1))
        rig.events.yield(rig.flow(2, .denied(.policy(.blockedPort(22)))))
        rig.events.yield(rig.flow(3, .closed(.finished)))
        await rig.settle { rig.activity.flows.count == 2 }

        #expect(rig.activity.flows.map(\.outcome) == [.denied, .allowed], "newest first, and a normal close is not a line")
        #expect(rig.activity.allowedCount == 1)
        #expect(rig.activity.deniedCount == 1)
        rig.activity.stop()
    }

    @Test func aFoldedDenialCountsForEveryAttemptItStandsFor() async {
        let rig = ActivityRig()
        rig.activity.start()
        let folded = FlowEvent(
            flowID: 1, transport: .udp, phase: .denied(.gatewayService(port: 123)), remote: (IPv4.make(198, 18, 0, 1), 123), name: nil,
            time: 0, count: 40)
        rig.events.yield(folded)
        await rig.settle { rig.activity.flows.count == 1 }

        #expect(rig.activity.deniedCount == 40, "40 refusals, one line")
        #expect(rig.activity.flows.first?.count == 40)
        rig.activity.stop()
    }

    @Test func theLogIsBoundedAndKeepsTheNewest() async {
        let rig = ActivityRig()
        rig.activity.start()
        let total = EditorLimits.recentFlowLimit + 25
        for id in 0..<total { rig.events.yield(rig.flow(UInt64(id))) }
        await rig.settle { rig.activity.allowedCount == total }

        #expect(rig.activity.allowedCount == total, "counts are not bounded")
        #expect(rig.activity.flows.count == EditorLimits.recentFlowLimit)
        #expect(rig.activity.flows.first?.id == total - 1)
        #expect(rig.activity.flows.last?.id == 25)
        rig.activity.stop()
    }

    @Test func aBurstOfEventsReachesTheObservedStateInOneUpdateWhenTheBatchIsDue() async throws {
        let rig = ActivityRig()
        rig.activity.start()
        for id in 0..<300 { rig.events.yield(rig.flow(UInt64(id), id.isMultiple(of: 3) ? .denied(.flowLimit) : .opened)) }

        await rig.idle()
        #expect(rig.activity.allowedCount + rig.activity.deniedCount == 0, "nothing reaches the main actor before the batch is due")

        try await rig.clock.waitForSleepers(atLeast: 1)
        rig.clock.advance(by: NetworkActivity.batchInterval)
        await rig.settle { rig.activity.allowedCount + rig.activity.deniedCount == 300 }
        #expect(rig.activity.allowedCount == 200)
        #expect(rig.activity.deniedCount == 100)
        #expect(rig.activity.flows.count == EditorLimits.recentFlowLimit)
        #expect(rig.activity.flows.first?.id == 299)
        rig.activity.stop()
    }

    @Test func aFullBatchIsAppliedWithoutWaitingForTheTimerAndTheRestFollows() async {
        let rig = ActivityRig()
        rig.activity.start()
        let total = NetworkActivity.batchLimit + 5
        for id in 0..<total { rig.events.yield(rig.flow(UInt64(id))) }

        var counted = 0
        for _ in 0..<2_000 where counted < NetworkActivity.batchLimit {
            try? await Task.sleep(for: .milliseconds(1))
            counted = rig.activity.allowedCount
        }
        #expect(counted == NetworkActivity.batchLimit, "a full batch needs no timer, and never exceeds the limit")

        await rig.settle { rig.activity.allowedCount == total }
        #expect(rig.activity.allowedCount == total)
        #expect(rig.activity.flows.first?.id == total - 1)
        rig.activity.stop()
    }

    @Test func theOutcomeOfAPhaseIsWhatItsLogLineSays() {
        let rig = ActivityRig()
        let phases: [FlowEvent.Phase] = [
            .opened, .answered(responseCode: 0), .answered(responseCode: 3), .denied(.unroutable), .denied(.policy(.blockedPort(22))),
            .closed(.finished), .closed(.guestReset), .closed(.idleTimeout), .closed(.hostError(54)),
            .closed(.policyRevoked(.blockedPort(22))), .closed(.stackStopped),
        ]
        for phase in phases {
            #expect(FlowLogEntry.outcome(of: phase) == FlowLogEntry(event: rig.flow(1, phase), id: 0)?.outcome, "\(phase)")
        }
    }

    @Test func guestAndHostVPNSignalsAreCombined() async {
        let rig = ActivityRig()
        rig.activity.start()
        #expect(rig.activity.vpn.level == .quiet)

        rig.hostFeed.yield([InterfaceSnapshot(name: "utun4", isUp: true, addresses: nil)])
        await rig.settle { rig.activity.vpn.host == .active }
        #expect(rig.activity.vpn.level == .hostVPN)

        rig.vpn.yield(.suspected(kind: .openVPN, confidence: .medium, since: 2, evidence: []))
        await rig.settle { rig.activity.guestVPN.kind != nil }
        #expect(rig.activity.vpn.level == .guestVPN)
        #expect(rig.activity.vpn.guestText == "Guest VPN: OpenVPN suspected (medium confidence)")
        #expect(rig.activity.vpn.hostText == "Mac VPN: active")

        rig.activity.stop()
        #expect(rig.activity.vpn.host == .unknown, "a stopped monitor does not vouch for the network")
    }

    @Test func anEditedPolicyIsForwardedOnlyWhileRunningAndOnlyWhenItChanged() {
        let rig = ActivityRig()
        var edited = NetworkPolicy()
        edited.blockPrivateRanges = false

        #expect(!rig.activity.apply(edited), "not started yet")
        rig.activity.start()
        #expect(!rig.activity.apply(NetworkPolicy()), "unchanged")
        #expect(rig.activity.apply(edited))
        #expect(!rig.activity.apply(edited), "already applied")
        #expect(rig.forwarded == [edited])
        #expect(rig.forwardedActions == [.terminate], "a tightened rule must also end the connections it forbids")
        #expect(rig.activity.policy == edited)

        rig.activity.stop()
        var later = edited
        later.mode = .allowListed
        #expect(!rig.activity.apply(later), "stopped")
        #expect(rig.forwarded == [edited])
    }

    @Test func stopShutsTheStackDownOnceAndIgnoresLaterEvents() async throws {
        let rig = ActivityRig()
        rig.activity.start()
        rig.activity.stop()
        rig.activity.stop()
        _ = try await rig.shutdowns.wait(forAtLeast: 1)
        #expect(rig.shutdowns.count == 1)
        #expect(!rig.activity.isRunning)

        rig.events.yield(rig.flow(1))
        for _ in 0..<50 { await Task.yield() }
        #expect(rig.activity.flows.isEmpty)
    }

    @Test func stopBeforeStartStillReleasesTheStackAndStartThenDoesNothing() async throws {
        let rig = ActivityRig()
        rig.activity.stop()
        _ = try await rig.shutdowns.wait(forAtLeast: 1)

        rig.activity.start()
        #expect(rig.begun == 0, "a stopped stack stays stopped")
        #expect(!rig.activity.isRunning)
    }
}

@MainActor
struct ControllerNetworkTests {
    private func makeMachine(in library: VMLibrary) throws -> VMConfig {
        var config = VMConfig.new(name: "net", guest: .linux)
        config.networkMode = .filtered
        try library.add(config)
        return config
    }

    @Test func aPolicyEditedWhileTheMachineRunsReachesItsNetwork() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory, saveDelay: .seconds(3600))
        var config = try makeMachine(in: library)
        let controller = library.controller(for: config.id)
        let made = try UserNetStack.make(pathChanges: { AsyncStream { _ in } })

        controller.beginNetwork(made.stack, policy: config.networkPolicy)
        let activity = try #require(controller.network)
        #expect(activity.isRunning)

        config.name = "renamed"
        library.update(config)
        #expect(activity.policy == NetworkPolicy(), "an unrelated edit is not a policy change")

        try config.networkPolicy.add("evil.com", to: .blockedDomains)
        library.update(config)
        #expect(activity.policy.rules(in: .blockedDomains) == ["evil.com"])

        activity.stop()
        await made.stack.stop()
        close(made.guestDescriptor)
    }

    @Test func aMachineWithNoStackHasNoActivityAndIgnoresPolicyEdits() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory, saveDelay: .seconds(3600))
        var config = try makeMachine(in: library)
        let controller = library.controller(for: config.id)

        controller.beginNetwork(nil, policy: config.networkPolicy)
        try config.networkPolicy.add("22", to: .blockedPorts)
        library.update(config)

        #expect(controller.network == nil)
    }

    @Test func aFreshStartReplacesAndStopsTheEarlierActivity() async throws {
        let controller = VMController()
        let first = try UserNetStack.make(pathChanges: { AsyncStream { _ in } })
        let second = try UserNetStack.make(pathChanges: { AsyncStream { _ in } })

        controller.beginNetwork(first.stack, policy: NetworkPolicy())
        let firstActivity = try #require(controller.network)
        controller.beginNetwork(second.stack, policy: NetworkPolicy())

        #expect(!firstActivity.isRunning)
        #expect(controller.network !== firstActivity)
        #expect(controller.network?.isRunning == true)

        controller.network?.stop()
        await first.stack.stop()
        await second.stack.stop()
        close(first.guestDescriptor)
        close(second.guestDescriptor)
    }

    @Test func changingTheNetworkModeDiscardsSavedStateButOtherEditsDoNot() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory, saveDelay: .seconds(3600))
        var config = try makeMachine(in: library)
        let bundle = library.bundle(config.id)
        try Data("memory".utf8).write(to: bundle.savedState)

        config.networkPolicy.blockPrivateRanges = false
        config.name = "other"
        library.update(config)
        #expect(bundle.hasSavedState, "the policy is applied by the host, so a saved guest is still valid")

        config.networkMode = .nat
        library.update(config)
        #expect(!bundle.hasSavedState, "a different network device can't take a saved state")
    }
}
