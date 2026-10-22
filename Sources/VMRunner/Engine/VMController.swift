import Foundation
import Observation
import Virtualization
import os

/// Owns the one `MachineState` of a machine and carries out what its transitions ask for.
///
/// The state moves only through `MachineState.transition(on:)`. A request from the interface and a report from the
/// framework are both events; the controller applies the event, then performs the effects it returned, and an effect that
/// waits for the framework reports its outcome as the next event. Nothing else sets `state`, so the interface never sees
/// a state the rules do not allow, and it does not depend on the framework announcing its own state.
///
/// Every report that can arrive late (the guest stopping, a framework call finishing, the runtime limit) carries the run
/// it belongs to. Releasing a machine ends its run, so whatever it still has in flight is dropped when it comes back, and
/// cannot touch the run that replaced it.
@MainActor @Observable
final class VMController {
    private(set) var state = MachineState.stopped
    /// The machine of this run, from the end of preparation until it is released.
    private(set) var guest: (any GuestMachine)?
    /// When the runtime limit will shut the machine down, if one is set.
    private(set) var deadline: Date?
    /// The live view of this run's filtered network; `nil` for other network modes and while stopped.
    private(set) var network: NetworkActivity?
    private(set) var suspendSupport: SuspendSupport?
    /// When the current run began its firmware (a cold boot); `nil` while stopped and for a run restored from saved state.
    private(set) var firmwareStartedAt: ContinuousClock.Instant?
    var errorMessage: String?

    /// What a start needs again if it falls back to a cold boot, and what the rest of the run needs from it.
    private struct Launch {
        var config: VMConfig
        let bundle: VMBundle
        weak var library: VMLibrary?
        let display: (width: Int, height: Int)
        let suspendAllowed: Bool
        var disposableCopyMade = false
    }

    /// Bumped each time a machine is released: a report that carries an older number is stale.
    @ObservationIgnored private var run: UInt64 = 0
    @ObservationIgnored private var launch: Launch?
    @ObservationIgnored private var notice: String?
    @ObservationIgnored private var stopIssued = false
    @ObservationIgnored private let factory: any MachineFactory
    @ObservationIgnored private let runtimeLimit: RuntimeLimit
    /// Held from the end of preparation until the machine is let go, so it ends on every path that ends a run.
    @ObservationIgnored private let latency: LatencyActivity

    init(
        factory: any MachineFactory = VZMachineFactory(), runtimeLimit: RuntimeLimit = RuntimeLimit(clock: ContinuousClock()),
        latency: LatencyActivity = .shared
    ) {
        self.factory = factory
        self.runtimeLimit = runtimeLimit
        self.latency = latency
    }

    var isActive: Bool { state.isActive }
    /// The framework's machine, for the view that displays it.
    var virtualMachine: VZVirtualMachine? { guest?.virtualMachine }
    /// Whether Suspend can be used now: the state allows it and this run's configuration can be saved.
    var canSuspend: Bool { state.allowsSuspend && suspendSupport == .available }
    /// Why Suspend is unavailable, when this run's configuration cannot be saved.
    var suspendUnavailableReason: String? {
        if case .unavailable(let reason) = suspendSupport { reason } else { nil }
    }

    // MARK: Requests

    /// Boots the machine, restoring saved state when present.
    ///
    /// Failures are reported through `errorMessage`; the controller is back in its stopped state afterwards.
    func start(_ config: VMConfig, bundle: VMBundle, library: VMLibrary, windowSize: CGSize? = nil) async {
        guard state.canStart else { return }
        errorMessage = nil
        var config = config
        // Without a stored MAC, Virtualization picks a random one per boot, which makes saved state unrestorable.
        if config.networkMode.hasNetworkDevice, config.macAddress.flatMap({ VZMACAddress(string: $0) }) == nil {
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
            library.update(config)
        }
        // A memory snapshot is only valid for the exact disk it was taken against, and disposable or
        // locked-down machines must never leave one behind.
        let mayResume = config.allowsSuspend && !config.ephemeral
        if !mayResume { bundle.discardSavedState() }
        let restoring = bundle.hasSavedState
        let decision = StartDisplay.decide(for: config, window: windowSize, restoring: restoring)
        let display = decision.size
        decision.log(config: config, window: windowSize, restoring: restoring)
        if !restoring {
            config.lastDisplayWidth = display.width
            config.lastDisplayHeight = display.height
            library.update(config)
        }
        launch = Launch(config: config, bundle: bundle, library: library, display: display, suspendAllowed: mayResume)
        await drive(.startRequested, run: run)
    }

    /// Asks the guest to shut down cleanly (like pressing the power button).
    func requestStop() { _ = receive(.shutdownRequested, run: run) }

    /// Stops immediately, like pulling the power cord, and releases the machine. Asked twice, it stops waiting for the
    /// framework and lets the machine go.
    func forceStop() async { await drive(.forceStopRequested, run: run) }

    func pause() async { await drive(.pauseRequested, run: run) }
    func resume() async { await drive(.resumeRequested, run: run) }

    /// Pauses, writes the machine state to the bundle, then stops. The next start restores it.
    ///
    /// If any step fails the state file is removed: a memory image next to a disk that keeps changing would
    /// restore into a corrupted guest.
    func suspend() async { await drive(.suspendRequested(supported: suspendSupport == .available), run: run) }

    /// The app is quitting: let go of what the process would otherwise leave behind. The machine itself goes with the process.
    func quit() { _ = receive(.quit, run: run) }

    /// Forwards an edited policy to the running stack, if there is one. Other network settings apply at the next start.
    func networkPolicyDidChange(_ policy: NetworkPolicy) {
        network?.apply(policy)
    }

    // MARK: Events

    /// Applies one event to the state and performs the effects that need no waiting. Returns the effects that do wait,
    /// for `carryOut`. An event of a run that has ended is dropped.
    private func receive(_ event: MachineEvent, run token: UInt64) -> [MachineEffect] {
        guard token == run else {
            Log.machine.debug("Dropped a report from an earlier run")
            return []
        }
        switch state.transition(on: event) {
        case .ignored:
            return []
        case .refused(let refusal):
            if event.isRequest, let message = refusal.message(suspendReason: suspendUnavailableReason) { errorMessage = message }
            return []
        case .moved(let next, let effects):
            if next != state {
                Log.machine.debug(
                    "Machine \(String(describing: self.state), privacy: .public) -> \(String(describing: next), privacy: .public)")
            }
            state = next
            var waiting: [MachineEffect] = []
            for effect in effects {
                if effect.waits {
                    waiting.append(effect)
                } else if let followUp = perform(effect, run: token) {
                    waiting += receive(followUp, run: token)
                }
            }
            return waiting
        }
    }

    /// Applies an event and carries out every effect it leads to, waiting for the framework as needed.
    private func drive(_ event: MachineEvent, run token: UInt64) async {
        await carryOut(receive(event, run: token), run: token)
    }

    private func carryOut(_ effects: [MachineEffect], run token: UInt64) async {
        var queue = effects
        while !queue.isEmpty {
            let effect = queue.removeFirst()
            if let outcome = await perform(waiting: effect, run: token) { queue += receive(outcome, run: token) }
        }
    }

    /// An event that arrives from outside a request (a delegate callback, a timer).
    private func notify(_ event: MachineEvent, run token: UInt64) {
        let waiting = receive(event, run: token)
        if !waiting.isEmpty { Task { await carryOut(waiting, run: token) } }
    }

    // MARK: Effects that need no waiting

    private func perform(_ effect: MachineEffect, run token: UInt64) -> MachineEvent? {
        switch effect {
        case .prepare:
            return prepare(run: token)
        case .fallBackToColdBoot(let reason):
            notice = "Couldn't restore the suspended state (\(reason)). Booted normally instead."
            letGoOfAttempt()
            return prepare(run: token)
        case .discardSavedState:
            launch?.bundle.discardSavedState()
        case .recordFirstBoot:
            if let launch, let library = launch.library { recordFirstBoot(of: launch.config, in: library) }
        case .showNotice:
            errorMessage = notice
            notice = nil
        case .armRuntimeLimit:
            armRuntimeLimit(run: token)
        case .requestGuestStop:
            do { try guest?.requestStop() } catch { return .shutdownFailed(error.localizedDescription) }
        case .report(let message):
            errorMessage = message
        case .release:
            release()
        case .restoreState, .bootMachine, .pauseMachine, .resumeMachine, .suspendMachine, .stopMachine:
            break
        }
        return nil
    }

    /// Makes the machine and its network stack for the current attempt, and starts the stack before the machine.
    private func prepare(run token: UInt64) -> MachineEvent {
        guard let attempt = launch else { return .startFailed("The machine has nothing to start.") }
        do {
            if attempt.config.ephemeral && !attempt.disposableCopyMade {
                try attempt.bundle.prepareEphemeral(guest: attempt.config.guest)
                launch?.disposableCopyMade = true
            }
            // A configuration that failed to restore can't be reused, and neither can its network stack: each attempt
            // gets its own.
            let prepared = try factory.prepare(
                attempt.config, bundle: attempt.bundle, display: attempt.display, suspendAllowed: attempt.suspendAllowed)
            adopt(prepared, run: token)
            return .prepared(canRestore: prepared.suspend == .available && attempt.bundle.hasSavedState)
        } catch {
            Log.machine.error("Start failed (\(error.logKind, privacy: .public)): \(error.localizedDescription, privacy: .private)")
            return .startFailed(error.localizedDescription)
        }
    }

    private func adopt(_ prepared: PreparedMachine, run token: UInt64) {
        guest = prepared.machine
        latency.hold(for: ObjectIdentifier(self))
        suspendSupport = prepared.suspend
        network = prepared.network
        prepared.network?.start()
        prepared.machine.onGuestStopped = { [weak self] in self?.notify(.guestStopped, run: token) }
        prepared.machine.onStoppedWithError = { [weak self] message in self?.notify(.stoppedWithError(message), run: token) }
    }

    /// Provisioning is only consumed by a boot that keeps its result: a disposable clone or a recovery boot
    /// would discard the account that was just created.
    private func recordFirstBoot(of config: VMConfig, in library: VMLibrary) {
        guard !config.hasBooted, !config.ephemeral, !config.bootIntoRecovery else { return }
        var updated = config
        updated.hasBooted = true
        updated.provisioning.password = ""
        library.update(updated)
    }

    private func armRuntimeLimit(run token: UInt64) {
        runtimeLimit.cancel()
        guard let minutes = launch?.config.maxRuntimeMinutes, let limit = RuntimeLimit.duration(forMinutes: minutes) else { return }
        deadline = .now.addingTimeInterval(Double(limit.components.seconds))
        runtimeLimit.start(
            after: limit,
            requestStop: { [weak self] in self?.notify(.runtimeLimitReached, run: token) },
            forceStop: { [weak self] in await self?.drive(.forceStopRequested, run: token) }
        )
    }

    /// Lets go of a failed attempt's machine and stack, keeping the launch for the cold boot that follows.
    private func letGoOfAttempt() {
        network?.stop()
        network = nil
        guest?.onGuestStopped = nil
        guest?.onStoppedWithError = nil
        guest = nil
        latency.release(for: ObjectIdentifier(self))
        suspendSupport = nil
        firmwareStartedAt = nil
    }

    /// Every way a run ends comes through here: the network stack is stopped, the runtime limit cancelled, the disposable
    /// copy discarded, and the machine let go (which detaches it from the view). Reports still on their way are stale.
    private func release() {
        letGoOfAttempt()
        runtimeLimit.cancel()
        deadline = nil
        launch?.bundle.discardEphemeral()
        launch = nil
        notice = nil
        stopIssued = false
        run &+= 1
    }

    // MARK: Effects that wait for the framework

    private func perform(waiting effect: MachineEffect, run token: UInt64) async -> MachineEvent? {
        guard token == run, let machine = guest else { return nil }
        let outcome: MachineEvent?
        switch effect {
        case .restoreState: outcome = await restore(machine)
        case .bootMachine: outcome = await boot(machine)
        case .pauseMachine: outcome = await pause(machine)
        case .resumeMachine: outcome = await resume(machine)
        case .suspendMachine(let pauseFirst): outcome = await suspend(machine, pauseFirst: pauseFirst, run: token)
        case .stopMachine: outcome = await stop(machine)
        default: outcome = nil
        }
        // The run ended while the framework was busy (the machine was let go, or the next run began): the outcome belongs
        // to nobody. What it brought up must not be left running.
        guard token == run else {
            if machine.canStop { try? await machine.stop() }
            return nil
        }
        return outcome
    }

    private func boot(_ machine: any GuestMachine) async -> MachineEvent {
        firmwareStartedAt = .now
        do {
            try await machine.start()
            return .bootSucceeded
        } catch {
            Log.machine.error("Start failed (\(error.logKind, privacy: .public)): \(error.localizedDescription, privacy: .private)")
            return .startFailed(error.localizedDescription)
        }
    }

    private func restore(_ machine: any GuestMachine) async -> MachineEvent {
        guard let bundle = launch?.bundle else { return .restoreFailed(reason: "There is nothing to restore.") }
        do {
            try await machine.restoreState(from: bundle.savedState)
            bundle.discardSavedState()
            try await machine.resume()
            return .restoreSucceeded
        } catch {
            // Saved state is tied to the exact configuration; the start falls back to a cold boot.
            Log.machine.error(
                "Restore failed (\(error.logKind, privacy: .public)): \(error.localizedDescription, privacy: .private)")
            return .restoreFailed(reason: error.localizedDescription)
        }
    }

    private func pause(_ machine: any GuestMachine) async -> MachineEvent {
        do {
            try await machine.pause()
            return .pauseSucceeded
        } catch {
            return .pauseFailed(error.localizedDescription)
        }
    }

    private func resume(_ machine: any GuestMachine) async -> MachineEvent {
        do {
            try await machine.resume()
            return .resumeSucceeded
        } catch {
            return .resumeFailed(error.localizedDescription)
        }
    }

    private func suspend(_ machine: any GuestMachine, pauseFirst: Bool, run token: UInt64) async -> MachineEvent {
        guard let bundle = launch?.bundle else { return .suspendFailed("There is no machine to suspend.", paused: false) }
        var paused = !pauseFirst
        do {
            if pauseFirst {
                try await machine.pause()
                paused = true
            }
            try await machine.saveState(to: bundle.savedState)
            // The run ended while the image was being written: nobody who ended it knew an image was coming, and it would
            // outlive a machine that is already let go.
            guard token == run else {
                bundle.discardSavedState()
                return .suspendFailed("The machine was released first.", paused: true)
            }
            try bundle.restrictSavedState()
            stopIssued = true
            try await machine.stop()
            return .suspendSucceeded
        } catch {
            // A memory image next to a disk that keeps changing would restore into a corrupted guest. When the run has
            // ended meanwhile, whoever ended it already dealt with the file.
            if token == run {
                bundle.discardSavedState()
                stopIssued = false
            }
            return .suspendFailed(error.localizedDescription, paused: paused)
        }
    }

    /// Stops the machine now if the framework allows it. When a call is still in flight the stop waits for it: the state
    /// asks for it again when that call finishes.
    private func stop(_ machine: any GuestMachine) async -> MachineEvent? {
        guard machine.canStop, !stopIssued else { return nil }
        stopIssued = true
        do {
            try await machine.stop()
            return .stopCompleted(failure: nil)
        } catch {
            return .stopCompleted(failure: error.localizedDescription)
        }
    }
}
