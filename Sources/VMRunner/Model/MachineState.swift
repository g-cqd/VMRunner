/// The state of one machine, and the only rules that move it.
///
/// `MachineState.transition(on:)` is a pure function: it reads the state and one event and says where the machine goes and
/// which effects the controller carries out, or that nothing happens. It touches no framework, file, clock or task, so
/// every state against every event is a table in the tests. `VMController` owns the one current value and performs the
/// effects; the interface only reads it.
///
/// There are two ways for an event to change nothing, and they mean different things:
/// - `refused`: the user (or a script) asked for something this state does not allow. The caller may say why.
/// - `ignored`: a late report for something this state no longer waits for (a callback that lost a race). It is dropped
///   without a word.
enum MachineState: Hashable, Sendable {
    /// What a start is doing. Preparation (the configuration, the network stack, the disposable copy) is synchronous, so
    /// `preparing` is only ever seen between two events of the same turn, and by the tests.
    enum StartPhase: Hashable, Sendable {
        /// `allowsRestore` is false after a restore failed: the retry is a cold boot whatever is on disk.
        case preparing(allowsRestore: Bool)
        case restoring
        case booting
    }

    case stopped
    case starting(StartPhase)
    case running
    /// The guest was asked to shut down and has not yet. The machine still runs, so everything `running` allows is
    /// allowed: a guest that ignores the request must not leave the user without a way out.
    case shuttingDown
    case pausing
    case paused
    case resuming
    /// Pausing if needed, writing the memory image, and stopping, as one step.
    case suspending
    /// A force stop was asked for and is not finished: either the stop itself is in flight, or an earlier framework call is
    /// in flight and the stop follows it. Asking again gives up waiting.
    case stopping

    /// Every state, for tests and for walking the graph.
    static let all: [Self] = [
        .stopped, .starting(.preparing(allowsRestore: true)), .starting(.preparing(allowsRestore: false)), .starting(.restoring),
        .starting(.booting), .running, .shuttingDown, .pausing, .paused, .resuming, .suspending, .stopping,
    ]

    // MARK: What the interface offers

    var isActive: Bool { self != .stopped }
    var canStart: Bool { self == .stopped }
    /// Running, whether or not a shutdown was asked for.
    private var isRunningNormally: Bool { self == .running || self == .shuttingDown }
    /// The state allows a suspend; whether this machine's configuration supports one is the controller's half of the answer.
    var allowsSuspend: Bool { isRunningNormally || self == .paused }

    /// What the machine is doing, in a lower-case phrase for a sentence.
    var activity: String {
        switch self {
        case .stopped: "stopped"
        case .starting(.restoring): "resuming from suspended state"
        case .starting: "starting"
        case .running: "running"
        case .shuttingDown: "shutting down"
        case .pausing: "pausing"
        case .paused: "paused"
        case .resuming: "resuming"
        case .suspending: "suspending"
        case .stopping: "stopping"
        }
    }

    /// What the sidebar dot says.
    enum Indicator: Hashable, Sendable { case none, running, paused, busy }

    var indicator: Indicator {
        switch self {
        case .stopped: .none
        case .running: .running
        case .paused, .pausing, .resuming: .paused
        case .starting, .shuttingDown, .suspending, .stopping: .busy
        }
    }

    // MARK: Transitions

    func transition(on event: MachineEvent) -> MachineTransition {
        switch event {
        case .startRequested: start()
        case .prepared(let canRestore): prepared(canRestore: canRestore)
        case .bootSucceeded: bootSucceeded()
        case .restoreSucceeded: restoreSucceeded()
        case .restoreFailed(let reason): restoreFailed(reason)
        case .startFailed(let message): startFailed(message)
        case .pauseRequested: pause()
        case .pauseSucceeded: settle(from: .pausing, to: .paused)
        case .pauseFailed(let message): settle(from: .pausing, to: .running, reporting: message)
        case .resumeRequested: resume()
        case .resumeSucceeded: settle(from: .resuming, to: .running)
        case .resumeFailed(let message): settle(from: .resuming, to: .paused, reporting: message)
        case .shutdownRequested: shutDown()
        case .shutdownFailed(let message): shutdownFailed(message)
        case .runtimeLimitReached: self == .running ? .moved(.shuttingDown, [.requestGuestStop]) : .ignored
        case .forceStopRequested: forceStop()
        case .stopCompleted(let failure): stopCompleted(failure)
        case .guestStopped: guestStopped(error: nil)
        case .stoppedWithError(let message): guestStopped(error: message)
        case .suspendRequested(let supported): suspend(supported: supported)
        case .suspendSucceeded: suspendSucceeded()
        case .suspendFailed(let message, let paused): suspendFailed(message, paused: paused)
        case .quit: quit()
        }
    }

    private func start() -> MachineTransition {
        guard self == .stopped else { return .refused(.redundant) }
        return .moved(.starting(.preparing(allowsRestore: true)), [.prepare])
    }

    private func prepared(canRestore: Bool) -> MachineTransition {
        guard case .starting(.preparing(let allowsRestore)) = self else { return .ignored }
        if allowsRestore && canRestore { return .moved(.starting(.restoring), [.restoreState]) }
        // A cold boot makes any memory image on disk wrong for the disk that is about to change.
        return .moved(.starting(.booting), [.discardSavedState, .bootMachine])
    }

    private func bootSucceeded() -> MachineTransition {
        switch self {
        case .starting(.booting): .moved(.running, [.recordFirstBoot, .showNotice, .armRuntimeLimit])
        case .stopping: .moved(.stopping, [.stopMachine])
        default: .ignored
        }
    }

    private func restoreSucceeded() -> MachineTransition {
        switch self {
        case .starting(.restoring): .moved(.running, [.armRuntimeLimit])
        case .stopping: .moved(.stopping, [.stopMachine])
        default: .ignored
        }
    }

    private func restoreFailed(_ reason: String) -> MachineTransition {
        switch self {
        case .starting(.restoring):
            .moved(.starting(.preparing(allowsRestore: false)), [.discardSavedState, .fallBackToColdBoot(reason: reason)])
        // The user gave up on this run: no cold boot.
        case .stopping: .moved(.stopped, [.release])
        default: .ignored
        }
    }

    private func startFailed(_ message: String) -> MachineTransition {
        switch self {
        case .starting: .moved(.stopped, [.release, .report(message)])
        case .stopping: .moved(.stopped, [.release])
        default: .ignored
        }
    }

    private func pause() -> MachineTransition {
        switch self {
        case .running, .shuttingDown: .moved(.pausing, [.pauseMachine])
        case .paused: .refused(.alreadyPaused)
        case .pausing: .refused(.redundant)
        case .stopped: .refused(.notActive)
        default: .refused(.busy(self))
        }
    }

    private func resume() -> MachineTransition {
        switch self {
        case .paused: .moved(.resuming, [.resumeMachine])
        case .running, .shuttingDown: .refused(.notPaused)
        case .resuming: .refused(.redundant)
        case .stopped: .refused(.notActive)
        default: .refused(.busy(self))
        }
    }

    private func shutDown() -> MachineTransition {
        switch self {
        // Asking again is allowed: the guest may have missed or dismissed the first request.
        case .running, .shuttingDown: .moved(.shuttingDown, [.requestGuestStop])
        case .paused: .refused(.pausedMachine)
        case .stopped: .refused(.notActive)
        default: .refused(.busy(self))
        }
    }

    private func shutdownFailed(_ message: String) -> MachineTransition {
        self == .shuttingDown ? .moved(.running, [.report(message)]) : .ignored
    }

    /// A framework call that this state was waiting for has finished. While a force stop waits for it, the machine is still
    /// there, so the stop goes ahead.
    private func settle(from waiting: Self, to next: Self, reporting message: String? = nil) -> MachineTransition {
        switch self {
        case waiting: .moved(next, message.map { [.report($0)] } ?? [])
        case .stopping: .moved(.stopping, [.stopMachine])
        default: .ignored
        }
    }

    private func forceStop() -> MachineTransition {
        switch self {
        case .stopped: .refused(.notActive)
        // Nothing is bound yet, or the user already asked once and wants out now.
        case .starting(.preparing), .stopping: .moved(.stopped, [.release])
        default: .moved(.stopping, [.stopMachine])
        }
    }

    private func stopCompleted(_ failure: String?) -> MachineTransition {
        guard self == .stopping else { return .ignored }
        return .moved(.stopped, [.release] + (failure.map { [.report($0)] } ?? []))
    }

    private func guestStopped(error: String?) -> MachineTransition {
        switch self {
        case .stopped, .starting(.preparing): return .ignored
        default: break
        }
        var effects: [MachineEffect] = []
        // A memory image that was being written is not a memory image.
        if self == .suspending { effects.append(.discardSavedState) }
        effects.append(.release)
        // The user asked for this stop; an error from the machine they pulled the plug on is not news.
        if let error, self != .stopping { effects.append(.report("The virtual machine stopped: \(error)")) }
        return .moved(.stopped, effects)
    }

    private func suspend(supported: Bool) -> MachineTransition {
        switch self {
        case .running, .shuttingDown, .paused:
            if supported {
                .moved(.suspending, [.suspendMachine(pauseFirst: self != .paused)])
            } else {
                .refused(.unsupported)
            }
        case .suspending: .refused(.redundant)
        case .stopped: .refused(.notActive)
        default: .refused(.busy(self))
        }
    }

    private func suspendSucceeded() -> MachineTransition {
        switch self {
        case .suspending, .stopping: .moved(.stopped, [.release])
        default: .ignored
        }
    }

    private func suspendFailed(_ message: String, paused: Bool) -> MachineTransition {
        switch self {
        case .suspending: .moved(paused ? .paused : .running, [.report("Couldn't suspend: \(message)")])
        case .stopping: .moved(.stopping, [.stopMachine])
        default: .ignored
        }
    }

    private func quit() -> MachineTransition {
        switch self {
        case .stopped: .moved(.stopped, [])
        case .suspending: .moved(.stopped, [.discardSavedState, .release])
        default: .moved(.stopped, [.release])
        }
    }
}

enum MachineEvent: Hashable, Sendable {
    // The user, the library and the launch arguments.
    case startRequested
    case pauseRequested
    case resumeRequested
    case shutdownRequested
    case forceStopRequested
    /// `supported` is whether the machine's configuration can be saved at all; the state decides the rest.
    case suspendRequested(supported: Bool)
    case quit

    // What the controller learned while carrying out an effect.
    /// The configuration and network stack exist. `canRestore`: a memory image exists and this machine can restore it.
    case prepared(canRestore: Bool)
    case bootSucceeded
    case restoreSucceeded
    case restoreFailed(reason: String)
    case startFailed(String)
    case pauseSucceeded
    case pauseFailed(String)
    case resumeSucceeded
    case resumeFailed(String)
    case shutdownFailed(String)
    case suspendSucceeded
    /// `paused`: the machine is paused where the suspend left it, not running.
    case suspendFailed(String, paused: Bool)
    case stopCompleted(failure: String?)

    // What the machine itself reported, or the runtime limit's timer.
    case guestStopped
    case stoppedWithError(String)
    case runtimeLimitReached

    /// Whether a person or a script asked for it, as opposed to a report. Only a refused request is worth telling them.
    var isRequest: Bool {
        switch self {
        case .startRequested, .pauseRequested, .resumeRequested, .shutdownRequested, .forceStopRequested, .suspendRequested, .quit:
            true
        default:
            false
        }
    }
}

enum MachineEffect: Hashable, Sendable {
    // Done at once.
    /// Builds the configuration and the network stack and starts the stack; reports `prepared` or `startFailed`.
    case prepare
    /// Releases the failed attempt, then prepares a cold boot; reports `prepared` or `startFailed`.
    case fallBackToColdBoot(reason: String)
    case discardSavedState
    case recordFirstBoot
    /// Shows the note a fallback to a cold boot left, if any.
    case showNotice
    case armRuntimeLimit
    /// Presses the guest's power button; reports `shutdownFailed` if the framework refuses.
    case requestGuestStop
    case report(String)
    /// Stops the network stack, cancels the runtime limit, discards the disposable copy, detaches the machine from the view,
    /// and makes every report of this run stale.
    case release

    // Wait for the framework; each reports its outcome as an event.
    case restoreState
    case bootMachine
    case pauseMachine
    case resumeMachine
    case suspendMachine(pauseFirst: Bool)
    /// Stops the machine if the framework allows it now; otherwise the call in flight is followed by this effect.
    case stopMachine

    /// Whether carrying the effect out waits for the framework. In a list of effects only the last may.
    var waits: Bool {
        switch self {
        case .restoreState, .bootMachine, .pauseMachine, .resumeMachine, .suspendMachine, .stopMachine: true
        default: false
        }
    }
}

/// Why a request changed nothing.
enum Refusal: Hashable, Sendable {
    /// It asked for what is already so or already under way (a second click): nothing to say.
    case redundant
    /// The machine is stopped.
    case notActive
    case alreadyPaused
    /// Resume, while it runs.
    case notPaused
    /// Shut down, while paused: a frozen guest cannot answer.
    case pausedMachine
    /// A framework call is in flight, in the given state.
    case busy(MachineState)
    /// Suspend, for a configuration the framework cannot save.
    case unsupported

    /// What to tell the user, or `nil` when there is nothing to say. `suspendReason` is why this machine cannot suspend.
    func message(suspendReason: String?) -> String? {
        switch self {
        case .redundant: nil
        case .notActive: "The machine isn't running."
        case .alreadyPaused: "The machine is already paused."
        case .notPaused: "The machine isn't paused."
        case .pausedMachine: "A paused machine can't be asked to shut down. Resume it first, or use Force Stop."
        case .busy(let state): "The machine is \(state.activity). Try again when it has finished."
        case .unsupported: suspendReason ?? "Suspend isn't available for this machine."
        }
    }
}

enum MachineTransition: Hashable, Sendable {
    /// The state after the event (which may be the same) and what to do about it.
    case moved(MachineState, [MachineEffect])
    case ignored
    case refused(Refusal)
}
